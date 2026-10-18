defmodule Troupe.PodSettingsTest do
  @moduledoc """
  A session on a worker pod explains its configuration (root #655's follow-up): `/settings`
  shows what is in force in it, which the pod answers over the session's own connection
  (`config.get` naming it), each value and rule with where it came from, and changes none
  of it; and `troupe config --explain --session ID` prints what the session's daemon or pod
  says of it, as `troupe config --explain` says this machine's.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.CLI.SessionConfig
  alias Troupe.FakeRemote
  alias Troupe.Settings

  describe "/settings on a pod" do
    @describetag :remote

    test "shows what is in force in the session, with where each part came from, and changes nothing" do
      session = FakeRemote.session(id: "s-pod-settings", profile: "fixing", title: "on a pod")
      {remote, url} = start_remote!(sessions: [session])
      sid = attach!(connect!(remote, url), "s-pod-settings")
      {pid, session} = start_tui(sid)
      eventually(fn -> user_state(pid).commands != [] end)

      type(pid, "/settings")
      press(pid, "enter")

      eventually(fn -> user_state(pid).settings.view.pod? end)

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?({"config.get", %{"session_id" => "s-pod-settings"}}, &1)
             )

      text = screen_text(pid, session)
      assert text =~ ~r/max turns\s+7  · session/
      assert text =~ ~r/compact at\s+0\.6  · project/
      assert text =~ "deny   shell(curl)  · the worker profile (standard)"
      assert text =~ "in force in this session on its worker pod; nothing here changes it"
      assert text =~ "settings in force on the pod"

      to_setting(pid, "models.default")
      assert screen_text(pid, session) =~ "set by: the worker profile fixing (TROUPE_MODEL)"

      # From the top again: the page opens on its first setting.
      press(pid, "esc")
      type(pid, "/settings")
      press(pid, "enter")
      to_setting(pid, "max_turns")
      assert screen_text(pid, session) =~ "set by: the session's terms"

      for code <- ["enter", " ", "s"] do
        press(pid, code)
        assert user_state(pid).settings.editing == nil
        assert user_state(pid).settings.status == Settings.pod_line()
      end

      refute Enum.any?(FakeRemote.calls(remote), &match?({"config.set", _}, &1))
    end
  end

  describe "troupe config --explain --session" do
    @answer %{
      "keys" => [],
      "explain" => "configuration in force in session s-1, on a worker pod\n",
      "explain_status" => 0
    }

    test "prints what the daemon says of one of its own sessions" do
      me = self()

      io = %{
        daemon: fn params ->
          send(me, {:daemon, params})
          {:ok, @answer}
        end,
        pod: fn _sid, _params -> flunk("a session the daemon has is not asked of a pod") end
      }

      assert SessionConfig.explain("s-1", "max_turns", [], io) == {@answer["explain"], 0}
      assert_received {:daemon, %{session_id: "s-1", explain: "text", key: "max_turns"}}
    end

    test "asks the session's pod when the daemon does not have it, and prints its JSON" do
      me = self()
      json = %{"session_id" => "s-1", "pod" => true, "keys" => []}

      io = %{
        daemon: fn _params -> {:error, %{message: "not_found"}} end,
        pod: fn sid, params ->
          send(me, {:pod, sid, params})
          {:ok, %{"keys" => [], "explain" => json, "explain_status" => 0}}
        end
      }

      assert {printed, 0} = SessionConfig.explain("s-1", nil, [json: true], io)
      assert Jason.decode!(printed) == json
      assert_received {:pod, "s-1", %{session_id: "s-1", explain: "json"}}
    end

    test "says a session running nowhere has nothing in force" do
      io = %{
        daemon: fn _ -> {:error, %{message: "not_found"}} end,
        pod: fn _, _ -> {:error, :no_plane} end
      }

      assert {text, 1} = SessionConfig.explain("s-1", nil, [], io)
      assert text =~ "session s-1 is not running, here or on a worker pod"
    end

    test "a session on a pod, through the plane signed in to" do
      session = FakeRemote.session(id: "s-pod-explain", profile: "fixing", title: "on a pod")
      {remote, url} = start_remote!(sessions: [session])
      _origin = connect!(remote, url)

      io = %{SessionConfig.io() | daemon: fn _ -> {:error, %{message: "not_found"}} end}

      # The fake pod answers the keys alone, as a pod older than the explanation does.
      assert {text, 1} = SessionConfig.explain("s-pod-explain", nil, [], io)
      assert text =~ "too old to explain"
      assert Enum.any?(FakeRemote.calls(remote), &match?({"session.open", %{"mode" => "read"}}, &1))

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?({"config.get", %{"session_id" => "s-pod-explain", "explain" => "text"}}, &1)
             )
    end
  end
end
