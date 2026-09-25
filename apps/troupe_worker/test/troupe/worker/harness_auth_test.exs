defmodule Troupe.Worker.HarnessAuthTest do
  @moduledoc """
  Attaching to a session on a pod, and being refused.

  Every refusal here is one a worker has to make without the plane: the plane is not in
  the data path of a live session, so a pod that cannot reach it still has to know that
  this token is for another pod, that this one has expired, and that this collaborator
  was thrown off the session ten seconds ago.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.KMS
  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.Client
  alias Troupe.Protocol.Endpoint
  alias Troupe.Session.Memory
  alias Troupe.Worker.Auth

  @moduletag timeout: 180_000

  @dev_pod "worker-dev-0"
  @ux_pod "worker-ux-0"

  setup context do
    context = requires_tier(context)

    # The harness reuses the gateway's own connection supervisor, because a remote
    # session and a local one are the same server with a different door.
    start_supervised!(Troupe.Gateway.Connections)
    start_supervised!(Troupe.Gateway.Commands)

    {:ok, jwks} = Tokens.jwks()
    auth = start_supervised!({Auth, name: nil, worker_id: @dev_pod, jwks: jwks})

    port = start_harness!(auth)

    Map.merge(context, %{auth: auth, port: port, jwks: jwks})
  end

  describe "getting in" do
    test "an owner's token attaches with every scope", context do
      {:ok, client} = connect(context, token(context, role: "owner"))

      assert %{scopes: scopes, principal: principal} = Client.info(client)
      assert Enum.sort(scopes) == [:admin, :control, :observe]
      assert principal["subject"] == "owner@example.test"
      assert principal["role"] == "owner"
    end

    test "a token minted for a ux pod is refused by this dev pod", context do
      jwt = token(context, audience: @ux_pod)

      assert {:error, error} = connect(context, jwt)
      assert error.message == "unauthenticated"
      assert error.data["reason"] == "wrong_audience"
    end

    test "no token at all is refused", context do
      assert {:error, error} = connect(context, nil)
      assert error.message == "unauthenticated"
    end

    test "a token signed by another key is refused", context do
      other = JOSE.JWK.generate_key({:ec, "P-256"})

      jwt =
        other
        |> JOSE.JWT.sign(%{"alg" => "ES256"}, %{
          "sub" => "impostor@example.test",
          "aud" => @dev_pod,
          "role" => "owner",
          "exp" => System.system_time(:second) + 600
        })
        |> JOSE.JWS.compact()
        |> elem(1)

      assert {:error, error} = connect(context, jwt)
      assert error.data["reason"] == "bad_signature"
    end
  end

  describe "roles" do
    test "a viewer may watch but not steer, while events keep flowing", context do
      assert {:ok, _} = activate(context)
      {:ok, client} = connect(context, token(context, role: "viewer", session_id: context.session_id))

      assert Client.info(client).scopes == [:observe]

      assert {:ok, _} = Client.subscribe(client, "session:" <> context.session_id)

      assert {:error, error} =
               Client.call(client, "input.send", %{
                 "session_id" => context.session_id,
                 "text" => "do something"
               })

      assert error.message == "forbidden"
      assert error.data["required_scope"] == "control"

      assert {:error, approval} =
               Client.call(client, "approval.respond", %{
                 "session_id" => context.session_id,
                 "call_id" => "whatever",
                 "decision" => "allow"
               })

      assert approval.message == "forbidden"

      # Refused, not disconnected: the viewer is still watching, and a refusal that took
      # the stream down would make observing a session a fragile thing.
      assert {:ok, _} = Client.call(client, "session.get", %{"session_id" => context.session_id})
    end

    test "a collaborator's next command is refused once the plane revokes them", context do
      assert {:ok, _} = activate(context)

      {:ok, client} =
        connect(context, token(context, role: "collaborator", session_id: context.session_id, sub: "mate@example.test"))

      assert {:ok, _} =
               Client.call(client, "input.send", %{
                 "session_id" => context.session_id,
                 "text" => "hello"
               })

      # The plane pushes the revocation. The token in this client's hand is untouched
      # and still verifies perfectly.
      :ok = Auth.put_acl(context.auth, context.session_id, "mate@example.test", nil)

      assert {:error, error} =
               Client.call(client, "input.send", %{
                 "session_id" => context.session_id,
                 "text" => "and again"
               })

      assert error.message == "forbidden"
      assert error.data["reason"] == "access revoked"
    end
  end

  describe "one session per token" do
    # Two sessions on one pod, as there are in a cluster: this test's, and somebody
    # else's, in another team.
    setup context do
      assert {:ok, _} = activate(context)
      Map.put(context, :other, other_session!(context))
    end

    test "a token for one session cannot read, steer, watch or branch from another", context do
      {:ok, client} =
        connect(context, token(context, role: "owner", session_id: context.session_id))

      other = context.other

      requests = [
        {"session.get", %{"session_id" => other}, "session_id"},
        {"input.send", %{"session_id" => other, "text" => "do something"}, "session_id"},
        {"subscribe", %{"topic" => "session:" <> other}, "topic"},
        {"subscribe", %{"topic" => "presence:" <> other}, "topic"},
        {"subscribe", %{"topic" => "fleet"}, "topic"},
        {"session.create", %{"workspace" => context.workspace, "parent" => other}, "parent"},
        # Its own id in one field does not carry another's in the next.
        {"session.get", %{"session_id" => context.session_id, "parent" => other}, "parent"}
      ]

      answered =
        for {method, params, field} <- requests,
            not refused?(Client.call(client, method, params), field),
            do: {method, params}

      assert answered == []

      # Its own session is still its own.
      mine = context.session_id
      assert {:ok, %{"id" => ^mine}} = Client.call(client, "session.get", %{"session_id" => mine})
      assert {:ok, _} = Client.subscribe(client, "session:" <> mine)
    end

    test "a listing of the pod shows a token its own session and nobody else's", context do
      {:ok, client} =
        connect(context, token(context, role: "viewer", session_id: context.session_id))

      mine = context.session_id

      assert {:ok, %{"sessions" => [%{"id" => ^mine}]}} = Client.call(client, "session.list", %{})
      assert {:ok, %{"sessions" => [%{"id" => ^mine}]}} = Client.call(client, "fleet.get", %{})

      # The pod does hold both, as a token with no session in it can see.
      {:ok, unscoped} = connect(context, token(context, role: "owner"))
      assert {:ok, %{"sessions" => all}} = Client.call(unscoped, "session.list", %{})
      assert [mine, context.other] -- Enum.map(all, & &1["id"]) == []
    end

    test "a token with no session in it is held to the ACL of every session it names", context do
      {:ok, client} = connect(context, token(context, role: "owner", sub: "mate@example.test"))
      :ok = Auth.put_acl(context.auth, context.other, "mate@example.test", nil)

      for params <- [
            %{"topic" => "session:" <> context.other},
            %{"topic" => "presence:" <> context.other}
          ] do
        assert {:error, error} = Client.call(client, "subscribe", params)
        assert error.data["reason"] == "access revoked"
      end

      assert {:error, error} =
               Client.call(client, "session.create", %{
                 "workspace" => context.workspace,
                 "parent" => context.other
               })

      assert error.data["reason"] == "access revoked"

      # A session it has not been thrown off is still open to it.
      assert {:ok, _} = Client.subscribe(client, "session:" <> context.session_id)
    end
  end

  describe "one session, not the pod" do
    setup context do
      assert {:ok, _} = activate(context)
      context
    end

    test "a session's token is refused the pod's methods, and none of them runs", context do
      jwt = token(context, role: "owner", session_id: context.session_id)

      # Somewhere on the pod that is not the session's, with a brief in it to forget.
      elsewhere = Path.join(context.base, "elsewhere")
      brief = Memory.path(elsewhere)
      File.mkdir_p!(Path.dirname(brief))
      File.write!(brief, "# Project brief\n\n## Overview\n\nNot the session's.\n")

      requests = [
        {"session.create", %{"workspace" => elsewhere}},
        {"config.get", %{}},
        {"config.models", %{"provider" => "openai", "base_url" => "http://127.0.0.1:9"}},
        {"config.set", %{"provider" => "openai", "base_url" => "http://127.0.0.1:9"}},
        {"identity.get", %{}},
        {"identity.link", %{"subject" => "someone@example.test"}},
        {"identity.unlink", %{}},
        {"watch.set", %{"workspace" => elsewhere, "enabled" => true}},
        {"memory.get", %{"workspace" => elsewhere}},
        {"memory.forget", %{"workspace" => elsewhere}},
        {"agents.list", %{"workspace" => elsewhere}},
        {"workflows.list", %{"workspace" => elsewhere}},
        {"workspace.recent", %{}},
        {"workspace.search", %{"query" => ""}},
        {"worktree.list", %{"workspace" => elsewhere}},
        {"worktree.remove", %{"path" => elsewhere}},
        {"worktree.merge", %{"workspace" => context.workspace, "path" => elsewhere}},
        {"worktree.discard", %{"workspace" => context.workspace, "path" => elsewhere}}
      ]

      # A connection each, so one that a request takes down does not hide the rest.
      answered =
        for {method, params} <- requests,
            answer = call_once(context, jwt, method, params),
            not match?({:error, %{message: "forbidden", data: %{"method" => ^method}}}, answer),
            do: {method, answer}

      assert answered == []

      assert File.exists?(brief)
      assert Troupe.Identity.get() == nil
      assert Sessions.active_ids() == [context.session_id]

      # A method no worker has is still `method_not_found`, and the session's own still
      # answer on the same token.
      {:ok, client} = connect(context, jwt)
      assert {:error, %{message: "method_not_found"}} = Client.call(client, "no.such.method", %{})

      mine = context.session_id
      assert {:ok, %{"id" => ^mine}} = Client.call(client, "session.get", %{"session_id" => mine})
      assert {:ok, %{"servers" => _}} = Client.call(client, "mcp.status", %{"session_id" => mine})
    end

    test "a token with no session in it still has the pod's methods", context do
      {:ok, client} = connect(context, token(context, role: "owner"))

      assert {:ok, %{"workspaces" => _}} = Client.call(client, "workspace.recent", %{})

      assert {:ok, %{"workflows" => _}} =
               Client.call(client, "workflows.list", %{"workspace" => context.workspace})
    end
  end

  describe "expiry" do
    test "a connection is warned before exp and refreshes on the same connection", context do
      # A second past the warning threshold, so this is a test of the warning rather
      # than of the test's patience.
      jwt = token(context, lifetime: 121)
      {:ok, client} = connect(context, jwt)

      assert_receive {:troupe_notification, "auth.expiring", warning}, 10_000
      assert is_integer(warning["expires_at"])

      fresh = token(context, lifetime: 900)
      assert {:ok, result} = Client.call(client, "auth.refresh", %{"auth" => %{"token" => fresh}})
      assert result["scopes"] != []
      assert result["auth"]["expires_at"] > warning["expires_at"]

      # And the connection carries on: a refresh is not a reconnect.
      assert {:ok, _} = Client.call(client, "session.list", %{})
    end

    test "the next command after exp is rejected and the connection closes", context do
      # Minted in the past, so it is already expired by the time it is presented — but
      # inside the leeway the verifier allows, so `initialize` still accepts it.
      now = System.system_time(:second)
      jwt = token(context, lifetime: 20, now: now - 10)

      {:ok, client} = connect(context, jwt)
      assert {:ok, _} = Client.call(client, "session.list", %{})

      # Past exp now, by more than the leeway.
      Process.sleep(1_100)
      expired = token(context, lifetime: 1, now: now - 3_600)
      assert {:error, _} = Client.call(client, "auth.refresh", %{"auth" => %{"token" => expired}})

      assert eventually(fn -> not Process.alive?(client) end)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp start_harness!(auth) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    start_supervised!(
      {Troupe.Gateway.Listener,
       name: :"harness-#{port}",
       endpoint:
         Endpoint.remote(port, Auth.authenticator(auth),
           guard: Auth.guard(auth),
           narrow: &Auth.narrow/3
         )}
    )

    port
  end

  # Another team's session on the same pod, up and running. Its storage and key go when
  # the test does, after its tree has stopped: `activate/1` stops the tree on exit, and
  # exit callbacks run last-registered first.
  defp other_session!(context) do
    other = Troupe.Session.generate_id()
    team = "other-" <> context.team
    workspace = Path.join(context.base, "other-workspace")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      Storage.erase(context.store, other)
      KMS.adapter().destroy(team, other)
    end)

    assert {:ok, _} = activate(%{context | session_id: other, team: team, workspace: workspace})
    other
  end

  defp refused?({:error, %{message: "forbidden", data: %{"field" => field}}}, field), do: true
  defp refused?(_answer, _field), do: false

  defp call_once(context, jwt, method, params) do
    {:ok, client} = connect(context, jwt)

    try do
      Client.call(client, method, params)
    catch
      :exit, reason -> {:exit, reason}
    after
      Client.close(client)
    end
  end

  defp connect(context, jwt) do
    Client.connect(
      address: {127, 0, 0, 1},
      port: context.port,
      token: jwt,
      client_info: %{"name" => "test", "version" => "1"}
    )
  end

  defp token(context, opts) do
    claims =
      %{
        "sub" => Keyword.get(opts, :sub, "owner@example.test"),
        "role" => Keyword.get(opts, :role, "owner"),
        "team" => context.team
      }
      |> then(fn map ->
        case Keyword.get(opts, :session_id) do
          nil -> map
          session_id -> Map.put(map, "session_id", session_id)
        end
      end)

    mint_opts =
      [audience: Keyword.get(opts, :audience, @dev_pod)] ++
        Keyword.take(opts, [:lifetime, :now])

    {:ok, jwt, _payload} = Tokens.mint(claims, mint_opts)
    jwt
  end
end
