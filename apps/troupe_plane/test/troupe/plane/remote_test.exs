defmodule Troupe.Plane.RemoteTest do
  @moduledoc """
  A laptop's session offered to the plane and steered from another device (#58), from the plane's side: a laptop's one connection at `/v1/relay`, the people it
  shares a session with finding it in `remote.list` and attaching with `remote.open`'s
  token at `/v1/relay/session`, each relayed message checked on the way, no token ever
  reaching the laptop, a withdrawal ending every view, and a laptop that went shown
  offline since then with nothing queued for it.

  The laptop is played by the test, over a real socket, with the protocol's own client.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.{Client, SessionId}

  @moduletag timeout: 60_000

  @ada "ada@example.test"
  @bea "bea@example.test"
  @cy "cy@example.test"

  setup do
    {:ok, listener} =
      start_supervised({Bandit, plug: Router, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    Application.put_env(:troupe_plane, :oidc,
      issuer: "https://issuer.example.test",
      client_id: "troupe-cli",
      device_authorization_endpoint: "https://issuer.example.test/device",
      token_endpoint: "https://issuer.example.test/token"
    )

    Application.put_env(:troupe_plane, :oidc_verifier, &fake_verify/1)

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :oidc)
      Application.delete_env(:troupe_plane, :oidc_verifier)
    end)

    ctx = %{url: "http://127.0.0.1:#{port}", ws: "ws://127.0.0.1:#{port}"}
    tokens = Map.new([@ada, @bea, @cy], &{&1, plane_token(ctx, &1)})
    session_id = SessionId.generate()

    Map.merge(ctx, %{tokens: tokens, session_id: session_id})
  end

  describe "offering and finding" do
    test "the owner and the people it is shared with find it; anybody else does not", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, synced} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      assert [%{"session_id" => id, "shares" => [%{"subject" => @bea, "role" => "control"}]}] =
               synced["offers"]

      assert id == ctx.session_id

      {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
      assert row["id"] == ctx.session_id
      assert row["kind"] == "remote"
      assert row["state"] == "online"
      assert row["your_role"] == "control"
      assert row["workspace"] == "project", "the plane keeps the workspace's name, not its path"
      assert row["shares"] == nil

      {:ok, %{"sessions" => [own]}} = rpc(ctx, @ada, "remote.list", %{})
      assert own["your_role"] == "owner"
      assert [%{"subject" => @bea}] = own["shares"]

      assert {:ok, %{"sessions" => []}} = rpc(ctx, @cy, "remote.list", %{})
      assert {:error, %{"message" => "not_found"}} = rpc(ctx, @cy, "remote.open", %{"session_id" => ctx.session_id})
    end

    test "a person the plane does not know is refused by name", ctx do
      laptop = laptop!(ctx, @ada)

      assert {:error, %{message: "not_found", data: %{"person" => "nobody@example.test"}}} =
               Client.call(laptop, "relay.offer", %{
                 "session_id" => ctx.session_id,
                 "share" => [%{"person" => "nobody@example.test", "role" => "observe"}]
               })
    end

    test "another person's session cannot be offered over it", ctx do
      ada = laptop!(ctx, @ada)
      {:ok, _} = sync(ada, ctx.session_id, [])
      cy = laptop!(ctx, @cy, "d-cy")

      assert {:error, %{message: "conflict"}} =
               Client.call(cy, "relay.offer", %{"session_id" => ctx.session_id, "share" => []})
    end

    test "a page in a browser is not a laptop", ctx do
      assert {:ok, %{status: 403}} =
               Req.request(
                 method: :get,
                 url: ctx.url <> "/v1/relay",
                 headers: [{"origin", "https://evil.example.test"}],
                 retry: false
               )
    end
  end

  describe "steering through the relay" do
    test "a shared person's messages reach the laptop checked, and no token ever does", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      assert opened["endpoint"] == "/v1/relay/session"
      assert opened["kind"] == "remote"

      viewer = viewer!(ctx, laptop, opened["token"], @bea, "control")

      # A prompt goes through to the laptop, which answers it.
      task = Task.async(fn -> Client.call(viewer, "input.send", input(ctx)) end)
      {id, frame} = await_frame(laptop)
      assert frame["method"] == "input.send"
      answer(laptop, id, frame["id"], %{"accepted" => true})
      assert {:ok, %{"accepted" => true}} = Task.await(task)

      # Something about the laptop rather than the session is refused here, and the laptop
      # hears nothing of it.
      assert {:error, %{message: "forbidden"}} =
               Client.call(viewer, "fs.read", %{"session_id" => ctx.session_id, "path" => "a"})

      assert {:error, %{message: "forbidden"}} =
               Client.call(viewer, "input.send", %{input(ctx) | "session_id" => "s-other"})

      # A renewal is the plane's to answer, and its token stays here.
      {:ok, again} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})

      assert {:ok, %{"auth" => %{"expires_at" => _}}} =
               Client.call(viewer, "auth.refresh", %{"auth" => %{"token" => again["token"]}})

      refute_receive {:troupe_notification, "relay.frame", _}, 300
    end

    test "a person shared to observe is held to it on the plane", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "observe"}])
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      viewer = viewer!(ctx, laptop, opened["token"], @bea, "observe")

      assert {:error, %{message: "forbidden", data: %{"required_scope" => "control"}}} =
               Client.call(viewer, "input.send", input(ctx))

      refute_receive {:troupe_notification, "relay.frame", _}, 300
    end

    test "a token for another door does not open a relayed session", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      assert {:error, %{message: "unauthenticated"}} =
               Client.connect(url: ctx.ws <> "/v1/relay/session", token: ctx.tokens[@bea])
    end
  end

  describe "withdrawn and offline" do
    test "withdrawing ends every view at once", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      viewer = viewer!(ctx, laptop, opened["token"], @bea, "control")
      monitor = Process.monitor(viewer)

      {:ok, %{"withdrawn" => true}} = Client.call(laptop, "relay.withdraw", %{"session_id" => ctx.session_id})

      assert_receive {:troupe_notification, "relay.closed", %{"reason" => "withdrawn"}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      assert {:ok, %{"sessions" => []}} = rpc(ctx, @bea, "remote.list", %{})
    end

    test "a laptop that goes is shown offline since then, and nothing is queued for it", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      _viewer = viewer!(ctx, laptop, opened["token"], @bea, "control")

      Client.close(laptop)
      assert_receive {:troupe_notification, "relay.closed", %{"reason" => "the laptop went offline"}}, 5_000

      row =
        eventually(fn ->
          {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
          row["state"] == "offline" and row
        end)

      assert is_binary(row["offline_since"])

      assert {:error, %{"message" => "unavailable", "data" => %{"offline_since" => since}}} =
               rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})

      assert is_binary(since)

      # Back, it offers again what it still offers, and is found again.
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, %{"sessions" => [back]}} = rpc(ctx, @bea, "remote.list", %{})
      assert back["state"] == "online"
    end
  end

  # -- the laptop ---------------------------------------------------------------

  defp laptop!(ctx, subject, device \\ "d-ada") do
    {:ok, laptop} =
      Client.connect(
        url: ctx.ws <> "/v1/relay",
        token: ctx.tokens[subject],
        client_info: %{"name" => "troupe-daemon", "version" => "1"},
        capabilities: %{"relay" => true, "device" => device}
      )

    on_exit(fn -> Client.close(laptop) end)
    laptop
  end

  defp sync(laptop, session_id, share) do
    Client.call(laptop, "relay.sync", %{
      "offers" => [%{"session_id" => session_id, "workspace" => "/home/ada/project", "share" => share}]
    })
  end

  # A viewer attaching: its `initialize` is relayed to the laptop, without its token, and
  # the laptop's answer goes back.
  defp viewer!(ctx, laptop, token, subject, role) do
    test = self()

    task =
      Task.async(fn ->
        Client.connect(url: ctx.ws <> "/v1/relay/session", token: token, owner: test)
      end)

    assert_receive {:troupe_notification, "relay.open", opened}, 5_000
    assert opened["session_id"] == ctx.session_id
    assert opened["person"]["subject"] == subject
    assert opened["role"] == role

    {viewer_id, initialize} = await_frame(laptop)
    assert viewer_id == opened["viewer"]
    assert initialize["method"] == "initialize"
    refute Map.has_key?(initialize["params"], "auth"), "a token reached the laptop"

    answer(laptop, viewer_id, initialize["id"], %{
      "protocol_version" => "1",
      "principal" => %{"subject" => subject},
      "scopes" => ["observe"]
    })

    {:ok, viewer} = Task.await(task)
    viewer
  end

  defp await_frame(_laptop) do
    assert_receive {:troupe_notification, "relay.frame", %{"viewer" => id, "data" => data}}, 5_000
    {id, Jason.decode!(data)}
  end

  defp answer(laptop, viewer_id, id, result) do
    data = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    Client.notify(laptop, "relay.frame", %{"viewer" => viewer_id, "data" => data})
  end

  defp input(ctx) do
    %{"command_id" => "c-1", "session_id" => ctx.session_id, "text" => "hello from the train"}
  end

  # -- the rest -----------------------------------------------------------------

  defp eventually(fun, deadline \\ 5_000) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if deadline <= 0, do: flunk("condition never held")
        Process.sleep(50)
        eventually(fun, deadline - 50)

      truthy ->
        truthy
    end
  end

  defp fake_verify("good:" <> subject) do
    {:ok, %{"sub" => subject, "email" => subject, "name" => subject, "groups" => []}}
  end

  defp fake_verify(_token), do: {:error, :bad_signature}

  defp plane_token(ctx, subject) do
    {:ok, %{status: 200, body: body}} =
      Req.request(
        method: :post,
        url: ctx.url <> "/auth/exchange",
        json: %{"id_token" => "good:#{subject}"},
        retry: false
      )

    body["token"]
  end

  defp rpc(ctx, subject, method, params) do
    {:ok, %{body: body}} =
      Req.request(
        method: :post,
        url: ctx.url <> "/rpc",
        json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        headers: [{"authorization", "Bearer " <> ctx.tokens[subject]}],
        retry: false
      )

    case body do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
    end
  end
end
