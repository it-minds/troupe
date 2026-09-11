defmodule Troupe.Worker.HarnessAuthTest do
  @moduledoc """
  Attaching to a session on a pod, and being refused.

  Every refusal here is one a worker has to make without the plane: the plane is not in
  the data path of a live session, so a pod that cannot reach it still has to know that
  this token is for another pod, that this one has expired, and that this collaborator
  was thrown off the session ten seconds ago.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.Client
  alias Troupe.Protocol.Endpoint
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
       endpoint: Endpoint.remote(port, Auth.authenticator(auth), guard: Auth.guard(auth))}
    )

    port
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
