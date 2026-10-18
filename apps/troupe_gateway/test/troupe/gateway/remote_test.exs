defmodule Troupe.Gateway.RemoteTest do
  @moduledoc """
  A laptop's session offered to the plane and steered from another device (#58, Decision
  921), from the daemon's side: one connection it dials and renews, a remote person's
  messages relayed over it into an ordinary connection, held to the one session and to
  the daemon's own record of the share whatever the plane says, the transcript naming
  who did what from where, and a withdrawal or a drop ending every view at once.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Gateway.{FakePlane, FakeRelay}

  @ada "ada@example.test"
  @bea "bea@example.test"
  @cy "cy@example.test"

  setup context do
    plane = FakePlane.serve()
    relay = FakeRelay.serve()
    Application.put_env(:troupe_gateway, :relay_url, relay.url)

    on_exit(fn ->
      Application.delete_env(:troupe_gateway, :relay_url)
      Process.exit(relay.server, :normal)
      Process.exit(plane.server, :normal)
    end)

    ada = attach(context, @ada)

    {:ok, _} =
      Client.call(ada, "identity.link", %{
        "command_id" => Client.command_id(),
        "subject" => @ada,
        "display_name" => "Ada",
        "plane_url" => plane.url,
        "plane_token" => "plane-token"
      })

    %{plane: plane, relay: relay, ada: ada}
  end

  defp offer(ctx, session_id, share \\ []) do
    Client.call(ctx.ada, "remote.offer", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "share" => share
    })
  end

  # A remote person, relayed: opened, then initialised as their client would.
  defp viewer(ctx, viewer, session_id, subject, role) do
    :ok = FakeRelay.open(ctx.relay, viewer, session_id, subject, role)

    :ok =
      FakeRelay.request(ctx.relay, viewer, 0, "initialize", %{
        "protocol_version" => "1",
        "client_info" => %{"name" => "troupe-gui", "version" => "1"}
      })

    assert_receive {:relay_frame, ^viewer, %{"id" => 0, "result" => hello}}, 5_000
    hello
  end

  defp ask(ctx, viewer, id, method, params) do
    :ok = FakeRelay.request(ctx.relay, viewer, id, method, params)
    assert_receive {:relay_frame, ^viewer, %{"id" => ^id} = answer}, 10_000
    answer
  end

  describe "offering" do
    test "a session is offered over one connection the daemon dials, and its listing says so", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})

      assert {:ok, %{"remote" => remote}} = offer(ctx, session.id, [%{"person" => @bea, "role" => "control"}])

      assert_receive {:relay, "initialize", hello}, 5_000
      assert hello["client_info"]["name"] == "troupe-daemon"
      assert is_binary(hello["capabilities"]["device"])
      assert_receive {:relay, "relay.offer", %{"session_id" => id, "share" => share}}, 5_000
      assert id == session.id
      assert share == [%{"person" => @bea, "role" => "control"}]

      assert remote["state"] == "online"
      assert remote["owner"] == @ada
      assert [%{"subject" => @bea, "role" => "control"}] = remote["shares"]

      {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => session.id})
      assert got["remote"]["state"] == "online"
    end

    test "a private session is never offered", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"}, kind: :private)

      assert {:error, %{code: -32_004, data: %{"reason" => reason}}} = offer(ctx, session.id)
      assert reason =~ "private session is never offered"
      refute_receive {:relay, "relay.offer", _}, 300
    end

    test "nothing is offered without a token to offer it with", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})

      {:ok, _} =
        Client.call(ctx.ada, "identity.sign_out", %{
          "command_id" => Client.command_id(),
          "plane_url" => ctx.plane.url
        })

      assert {:error, %{code: -32_010, data: %{"reason" => reason}}} = offer(ctx, session.id)
      assert reason =~ "sign in to a plane first"
    end

    test "a person the plane does not know is refused by name, and nothing is recorded", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})

      FakeRelay.refuse_offers(ctx.relay, %{
        "code" => -32_005,
        "message" => "not_found",
        "data" => %{"reason" => "nobody@example.test has not signed in to this plane"}
      })

      assert {:error, %{code: -32_005}} = offer(ctx, session.id, [%{"person" => "nobody@example.test"}])
      {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => session.id})
      assert got["remote"] == nil
    end
  end

  describe "steering from another device" do
    test "the owner, remote, sends a prompt the transcript writes as theirs through the plane, and cancels",
         ctx do
      %{session: session} = start_session(ctx, default: {:text, "done"}, delay_ms: 300)
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "relay.offer", _}, 5_000

      hello = viewer(ctx, "v-own", session.id, @ada, "control")
      assert hello["principal"]["via"] == "plane"
      assert "control" in hello["scopes"]
      refute "admin" in hello["scopes"]
      assert hello["capabilities"]["relayed"] == true

      sub =
        ask(ctx, "v-own", 1, "subscribe", %{
          "command_id" => "c-sub",
          "topic" => "session:#{session.id}",
          "from_seq" => 0
        })

      assert %{"result" => %{"subscription_id" => _}} = sub

      assert %{"result" => %{"accepted" => true}} =
               ask(ctx, "v-own", 2, "input.send", %{
                 "command_id" => "c-in",
                 "session_id" => session.id,
                 "text" => "hello from the train"
               })

      accepted = await_event("v-own", "input_accepted")
      assert accepted["actor"]["subject"] == @ada
      assert accepted["actor"]["via"] == "plane"

      assert %{"result" => %{"accepted" => true}} =
               ask(ctx, "v-own", 3, "turn.cancel", %{"command_id" => "c-x", "session_id" => session.id})
    end

    test "a person shared at control answers an approval once, and may not allow for the session", ctx do
      %{session: session} =
        start_session(ctx,
          steps: [{:tools, [{"write_file", %{"path" => "a.txt", "content" => "hi"}}]}],
          default: {:text, "done"},
          config: [auto_approve: false]
        )

      {:ok, _} = offer(ctx, session.id, [%{"person" => @bea, "role" => "control"}])
      assert_receive {:relay, "relay.offer", _}, 5_000
      viewer(ctx, "v-bea", session.id, @bea, "control")

      ask(ctx, "v-bea", 1, "subscribe", %{"command_id" => "c-s", "topic" => "session:#{session.id}", "from_seq" => 0})

      ask(ctx, "v-bea", 2, "input.send", %{
        "command_id" => "c-1",
        "session_id" => session.id,
        "text" => "write it"
      })

      requested = await_event("v-bea", "approval_requested")
      call_id = requested["data"]["call_id"]

      assert %{"error" => %{"code" => -32_004, "data" => %{"field" => "decision"}}} =
               ask(ctx, "v-bea", 3, "approval.respond", %{
                 "command_id" => "c-2",
                 "session_id" => session.id,
                 "call_id" => call_id,
                 "decision" => "allow_session"
               })

      assert %{"result" => %{"accepted" => true}} =
               ask(ctx, "v-bea", 4, "approval.respond", %{
                 "command_id" => "c-3",
                 "session_id" => session.id,
                 "call_id" => call_id,
                 "decision" => "allow"
               })

      decided = await_event("v-bea", "approval_decided")
      assert decided["actor"]["subject"] == @bea
      assert decided["actor"]["via"] == "plane"
    end

    test "the daemon holds a person to its own record, whatever role the plane relays them at", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id, [%{"person" => @bea, "role" => "observe"}])
      assert_receive {:relay, "relay.offer", _}, 5_000

      hello = viewer(ctx, "v-bea", session.id, @bea, "control")
      assert hello["scopes"] == ["observe"]

      assert %{"error" => %{"code" => -32_004}} =
               ask(ctx, "v-bea", 1, "input.send", %{
                 "command_id" => "c-1",
                 "session_id" => session.id,
                 "text" => "let me"
               })

      # Somebody the laptop never shared it with is closed before a word reaches the session.
      :ok = FakeRelay.open(ctx.relay, "v-cy", session.id, @cy, "control")
      assert_receive {:relay_close, "v-cy", reason}, 5_000
      assert reason =~ "not shared"
    end

    test "only the session, and nothing of the laptop, is reached through the plane", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      %{session: other} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "relay.offer", _}, 5_000
      viewer(ctx, "v-own", session.id, @ada, "control")

      for {id, method, params} <- [
            {1, "fs.read", %{"session_id" => session.id, "path" => "a.txt"}},
            {2, "shell.run", %{"command_id" => "c-sh", "session_id" => session.id, "command" => "ls"}},
            {3, "tools.register", %{"command_id" => "c-t", "session_id" => session.id, "tools" => []}},
            {4, "session.create", %{"command_id" => "c-c", "workspace" => ctx.workspace}},
            {5, "input.send", %{"command_id" => "c-o", "session_id" => other.id, "text" => "hi"}},
            {6, "subscribe", %{"command_id" => "c-f", "topic" => "fleet"}},
            {7, "remote.withdraw", %{"command_id" => "c-w", "session_id" => session.id}}
          ] do
        assert %{"error" => %{"code" => -32_004}} = ask(ctx, "v-own", id, method, params),
               "#{method} reached the laptop"
      end

      assert %{"result" => %{"sessions" => [%{"id" => listed}]}} =
               ask(ctx, "v-own", 8, "session.list", %{})

      assert listed == session.id
    end

    test "the laptop's listing names who is steering, and leaving takes them off it", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id, [%{"person" => @bea, "role" => "control"}])
      assert_receive {:relay, "relay.offer", _}, 5_000
      viewer(ctx, "v-bea", session.id, @bea, "control")

      eventually(fn ->
        {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => session.id})
        match?([%{"subject" => @bea, "role" => "control"}], got["remote"]["steering"])
      end)

      :ok = FakeRelay.close(ctx.relay, "v-bea")

      eventually(fn ->
        {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => session.id})
        got["remote"]["steering"] == []
      end)
    end
  end

  describe "withdrawn and offline" do
    test "withdrawing ends every remote view of the session at once", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id, [%{"person" => @bea, "role" => "control"}])
      assert_receive {:relay, "relay.offer", _}, 5_000
      viewer(ctx, "v-own", session.id, @ada, "control")
      viewer(ctx, "v-bea", session.id, @bea, "control")

      {:ok, %{"remote" => nil}} =
        Client.call(ctx.ada, "remote.withdraw", %{
          "command_id" => Client.command_id(),
          "session_id" => session.id
        })

      assert_receive {:relay_close, "v-own", "withdrawn"}, 5_000
      assert_receive {:relay_close, "v-bea", "withdrawn"}, 5_000
      assert_receive {:relay, "relay.withdraw", %{"session_id" => id}}, 5_000
      assert id == session.id

      # A plane that relayed anything more reaches nobody.
      :ok = FakeRelay.request(ctx.relay, "v-bea", 9, "session.get", %{"session_id" => session.id})
      refute_receive {:relay_frame, "v-bea", _}, 500
    end

    test "a dropped connection ends the views; the daemon dials again and offers only what it still does",
         ctx do
      %{session: kept} = start_session(ctx, default: {:text, "ok"})
      %{session: gone} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, kept.id)
      {:ok, _} = offer(ctx, gone.id)
      # The first connection's, made for the first offer, with nothing recorded yet.
      assert_receive {:relay, "initialize", _}, 5_000
      assert_receive {:relay, "relay.sync", %{"offers" => []}}, 5_000
      assert_receive {:relay, "relay.offer", _}, 5_000
      assert_receive {:relay, "relay.offer", _}, 5_000
      viewer(ctx, "v-own", kept.id, @ada, "control")

      {:ok, _} =
        Client.call(ctx.ada, "remote.withdraw", %{"command_id" => Client.command_id(), "session_id" => gone.id})

      FakeRelay.drop(ctx.relay)

      eventually(fn ->
        {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => kept.id})
        got["remote"]["state"] in ["offline", "connecting"] and got["remote"]["steering"] == []
      end)

      assert_receive {:relay, "initialize", _}, 10_000
      assert_receive {:relay, "relay.sync", %{"offers" => offers}}, 5_000
      assert Enum.map(offers, & &1["session_id"]) == [kept.id]

      eventually(fn ->
        {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => kept.id})
        got["remote"]["state"] == "online"
      end)
    end

    test "a fresh token from a client renews the connection where it stands", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "relay.offer", _}, 5_000

      FakePlane.renew(ctx.plane.state, "plane-token-2")
      FakeRelay.renew(ctx.relay, "plane-token-2")

      {:ok, _} =
        Client.call(ctx.ada, "identity.link", %{
          "command_id" => Client.command_id(),
          "subject" => @ada,
          "plane_url" => ctx.plane.url,
          "plane_token" => "plane-token-2"
        })

      assert_receive {:relay, "auth.refresh", %{"auth" => %{"token" => "plane-token-2"}}}, 5_000
    end
  end

  # The next event of `type` the viewer was sent, as the plane would relay it.
  defp await_event(viewer, type) do
    receive do
      {:relay_frame, ^viewer, %{"method" => "event", "params" => %{"event" => %{"type" => ^type} = event}}} ->
        event
    after
      15_000 -> flunk("no #{type} reached #{viewer}")
    end
  end
end
