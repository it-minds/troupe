defmodule Troupe.Gateway.RemoteTest do
  @moduledoc """
  A laptop's session offered to the plane and steered from another device (#58), from the daemon's side: one connection it dials and renews, a remote person's
  messages relayed over it into an ordinary connection, held to the one session and to
  the daemon's own record of the share whatever the plane says, the transcript naming
  who did what from where, and a withdrawal or a drop ending every view at once.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Gateway.{Connections, FakePlane, FakeRelay, Idle, Plane, Remote}
  alias Troupe.Keyring
  alias Troupe.Keyring.Memory

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
      %{session: session} = start_session(ctx, default: {:text, "done"}, delay_ms: 2_000)
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

      # Stopping the turn is written as theirs too.
      cancelled = await_event("v-own", "cancelled")
      assert cancelled["actor"]["subject"] == @ada
      assert cancelled["actor"]["via"] == "plane"

      # The agent, from the picker's rows the laptop lists for the session.
      assert %{"result" => %{"agents" => agents}} =
               ask(ctx, "v-own", 4, "agents.list", %{"session_id" => session.id})

      assert "plan" in Enum.map(agents, & &1["name"])

      assert %{"result" => %{"accepted" => true, "profile" => "plan"}} =
               ask(ctx, "v-own", 5, "profile.switch", %{
                 "command_id" => "c-sw",
                 "session_id" => session.id,
                 "profile" => "plan"
               })

      switched = await_event("v-own", "profile_switched")
      assert switched["actor"]["via"] == "plane"
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
      # Another offered, so the one connection stays up for what the plane relays after.
      %{session: other} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, other.id)
      {:ok, _} = offer(ctx, session.id, [%{"person" => @bea, "role" => "control"}])
      assert_receive {:relay, "relay.offer", _}, 5_000
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

    test "the daemon renews its own token on the open socket before it runs out, and when warned", ctx do
      # A token that lives two minutes and five seconds is renewed five seconds in.
      FakePlane.laptop_lifetime(ctx.plane.state, 125)
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "initialize", %{"auth" => %{"token" => first}}}, 5_000
      assert_receive {:relay, "relay.offer", _}, 5_000

      assert_receive {:relay, "auth.refresh", %{"auth" => %{"token" => "laptop:" <> _ = renewed}}}, 15_000
      assert renewed != first

      # The plane's warning two minutes before asks for the same.
      FakePlane.laptop_lifetime(ctx.plane.state, 900)
      :ok = FakeRelay.expiring(ctx.relay)
      assert_receive {:relay, "auth.refresh", %{"auth" => %{"token" => "laptop:" <> _ = again}}}, 5_000
      assert again != renewed
    end
  end

  describe "the daemon's own sign-in (slice 2)" do
    test "the first offer asks the plane for a grant of its own, keeps it in the credential store, and dials with it",
         ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, %{"remote" => %{"state" => "online"}}} = offer(ctx, session.id)

      assert_receive {:relay, "initialize", hello}, 5_000
      assert "laptop:" <> _ = hello["auth"]["token"], "the relay rode on the client's token"
      device = hello["capabilities"]["device"]

      assert {"remote.grant", %{"device" => ^device}} =
               Enum.find(FakePlane.calls(ctx.plane.state), &match?({"remote.grant", _}, &1))

      [grant] = Map.keys(FakePlane.grants(ctx.plane.state))
      stored = stored(ctx)
      assert stored["grant"] == grant
      assert stored["subject"] == @ada
      assert stored["plane_url"] == ctx.plane.url
      refute inspect(stored) =~ "plane-token", "the client's token went into the store"

      # Nothing of it is in the daemon's files.
      for file <- Path.wildcard(Path.join(ctx.state_dir, "**/*"), match_dot: true), File.regular?(file) do
        refute File.read!(file) =~ grant, "#{file} holds the grant"
      end

      # A second offer rides the same sign-in.
      %{session: other} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, other.id)
      assert Enum.count(FakePlane.calls(ctx.plane.state), &match?({"remote.grant", _}, &1)) == 1
    end

    test "the offer stays online and steerable after the client that made it has closed", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id, [%{"person" => @bea, "role" => "control"}])
      assert_receive {:relay, "relay.offer", _}, 5_000

      Client.close(ctx.ada)

      hello = viewer(ctx, "v-bea", session.id, @bea, "control")
      assert hello["principal"]["subject"] == @bea

      assert %{"result" => %{"id" => id}} = ask(ctx, "v-bea", 1, "session.get", %{"session_id" => session.id})
      assert id == session.id
      assert Remote.describe(session.id)["state"] == "online"
    end

    test "a daemon that restarts with something offered comes back online from the store, with no client",
         ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "relay.offer", _}, 5_000
      grants = Enum.count(FakePlane.calls(ctx.plane.state), &match?({"remote.grant", _}, &1))

      # No client holds a token here any more, and the steering process starts again.
      :ok = Plane.unlink()
      Process.exit(Process.whereis(Remote), :kill)

      assert_receive {:relay, "initialize", %{"auth" => %{"token" => "laptop:" <> _}}}, 10_000
      assert_receive {:relay, "relay.sync", %{"offers" => [%{"session_id" => id}]}}, 5_000
      assert id == session.id

      assert Enum.count(FakePlane.calls(ctx.plane.state), &match?({"remote.grant", _}, &1)) == grants,
             "it asked for a new grant rather than using the one it kept"

      eventually(fn -> Remote.describe(session.id)["state"] == "online" end)
    end

    test "withdrawing the last offer releases the sign-in, takes it out of the store and closes the relay",
         ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      %{session: other} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      {:ok, _} = offer(ctx, other.id)
      assert_receive {:relay, "relay.offer", _}, 5_000
      assert_receive {:relay, "relay.offer", _}, 5_000
      [grant] = Map.keys(FakePlane.grants(ctx.plane.state))

      {:ok, _} = withdraw(ctx, other.id)
      assert stored(ctx)["grant"] == grant, "one offer still stands"
      assert FakeRelay.connected?(ctx.relay)

      {:ok, _} = withdraw(ctx, session.id)
      assert_receive {:relay, "relay.withdraw", _}, 5_000
      assert stored(ctx) == nil
      eventually(fn -> not FakeRelay.connected?(ctx.relay) end)
      eventually(fn -> FakePlane.released(ctx.plane.state) == [grant] end)
      refute Remote.offering?()
    end

    test "signing out releases it, takes it out of the store and closes the relay, and keeps the record", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "relay.offer", _}, 5_000
      [grant] = Map.keys(FakePlane.grants(ctx.plane.state))

      {:ok, %{"signed_out" => true}} =
        Client.call(ctx.ada, "identity.sign_out", %{
          "command_id" => Client.command_id(),
          "plane_url" => ctx.plane.url,
          "subject" => @ada
        })

      assert stored(ctx) == nil
      eventually(fn -> not FakeRelay.connected?(ctx.relay) end)
      eventually(fn -> FakePlane.released(ctx.plane.state) == [grant] end)
      assert Remote.describe(session.id)["state"] == "offline"

      # Signed in again, the same session is offered again on a new sign-in.
      {:ok, _} =
        Client.call(ctx.ada, "identity.link", %{
          "command_id" => Client.command_id(),
          "subject" => @ada,
          "plane_url" => ctx.plane.url,
          "plane_token" => "plane-token"
        })

      assert_receive {:relay, "relay.sync", %{"offers" => [%{"session_id" => id}]}}, 10_000
      assert id == session.id
      assert stored(ctx)["grant"] != grant
    end

    test "a team that forbids offering is refused by the plane, and the refusal says so", ctx do
      FakePlane.refuse_grants(
        ctx.plane.state,
        {-32_004, "forbidden",
         %{"team" => "eng", "reason" => "eng's administrators do not allow offering a laptop session"}}
      )

      %{session: session} = start_session(ctx, default: {:text, "ok"})

      assert {:error, %{code: -32_004, data: %{"team" => "eng", "reason" => reason}}} = offer(ctx, session.id)
      assert reason =~ "eng's administrators do not allow offering"
      assert stored(ctx) == nil
      refute FakeRelay.connected?(ctx.relay)
      refute Remote.offering?()
    end

    test "the idle watch stays up for an offer with nobody attached, and not once it is withdrawn", ctx do
      %{session: session} = start_session(ctx, default: {:text, "ok"})
      {:ok, _} = offer(ctx, session.id)
      assert_receive {:relay, "relay.offer", _}, 5_000

      # Nothing running and nobody attached: only the offer keeps the daemon up.
      Troupe.stop_session(session.id)
      Client.close(ctx.ada)
      eventually(fn -> Connections.count() == 0 and not Troupe.any_active_sessions?() end)

      assert Remote.offering?()
      assert Idle.busy?()

      :ok = Remote.withdraw(session.id)
      refute Remote.offering?()
      refute Idle.busy?()
    end
  end

  describe "after a restart" do
    test "an offer on a daemon that does not start at login is recorded as lasting until this machine restarts",
         ctx do
      {:ok, _} = Troupe.StartAtLogin.disable()
      %{session: session} = start_session(ctx, default: {:text, "ok"})

      assert {:ok, %{"remote" => remote}} = offer(ctx, session.id)
      assert remote["lasts"] == "until_restart"
      refute remote["restored"]

      {:ok, got} = Client.call(ctx.ada, "session.get", %{"session_id" => session.id})
      assert got["remote"]["lasts"] == "until_restart"
    end

    test "with the daemon started at login the offer lasts across restarts, and a restart brings it back, said so",
         ctx do
      {:ok, %{"at_login" => true}} = Troupe.StartAtLogin.enable()
      on_exit(fn -> Troupe.StartAtLogin.disable() end)

      %{session: session} = start_session(ctx, default: {:text, "ok"})
      assert {:ok, %{"remote" => remote}} = offer(ctx, session.id)
      assert remote["lasts"] == "across_restarts"
      refute remote["restored"]
      assert_receive {:relay, "relay.offer", _}, 5_000
      grants = Enum.count(FakePlane.calls(ctx.plane.state), &match?({"remote.grant", _}, &1))

      # The machine restarted: no client, and the daemon's steering starts from its record.
      :ok = Plane.unlink()
      Process.exit(Process.whereis(Remote), :kill)

      assert_receive {:relay, "relay.sync", %{"offers" => [%{"session_id" => id}]}}, 10_000
      assert id == session.id

      assert Enum.count(FakePlane.calls(ctx.plane.state), &match?({"remote.grant", _}, &1)) ==
               grants

      eventually(fn -> Remote.describe(session.id)["state"] == "online" end)
      assert %{"restored" => true, "lasts" => "across_restarts"} = Remote.describe(session.id)
    end
  end

  defp withdraw(ctx, session_id) do
    Client.call(ctx.ada, "remote.withdraw", %{"command_id" => Client.command_id(), "session_id" => session_id})
  end

  # What the credential store holds for this daemon's sign-in, decoded, or nil.
  defp stored(ctx) do
    name = Keyring.entry(Remote.keyring_name(ctx.state_dir))

    case Memory.get(name) do
      {:ok, text} -> text |> Base.url_decode64!(padding: false) |> Jason.decode!()
      :none -> nil
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
