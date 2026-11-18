defmodule Troupe.UnreadableLogTest do
  @moduledoc """
  A session whose log its agent cannot read (root #1053), on the daemon this VM embeds: a
  message cannot wake it, and the line under the screen says what the agent raised and
  offers `w`, which wakes it past the event, skipping it (the log keeps it), and sends the
  message then; the transcript says an event was skipped. `troupe resume ID --repair` is
  the same wake from the command line, which a headless run that could not send names.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.CLI.Runner

  @moduletag timeout: 120_000

  # Every start from here replays tool results that are not a list, and raises; the root's
  # Node gives up and the session stops on it, as `crash_loop_test.exs` makes one.
  defp unreadable(script) do
    {sid, _, ws} = start_session!(script: script)
    say!(sid, "hi")
    await_rest(sid)

    {:ok, poison} =
      Troupe.Session.Log.append(sid, ["root"], :tool_results, %{"results" => "not a list"})

    Process.exit(Troupe.Registry.agent_pid(sid, ["root"]), :kill)
    eventually(fn -> is_nil(Troupe.Registry.whereis({:session, sid})) end, 15_000)
    {sid, ws, poison}
  end

  defp await_rest(sid) do
    eventually(
      fn ->
        Enum.any?(Troupe.replay_from(sid, 0), &(&1.type == "turn_ended" and &1.agent == ["root"]))
      end,
      15_000
    )
  end

  defp notices(pid), do: user_state(pid).model.notices

  @tag :capture_log
  test "a message that cannot wake it offers w, which wakes it past the event and sends the message" do
    {sid, _ws, poison} =
      unreadable([{:text_and_tools, "Hello.", []}, {:text_and_tools, "Counted.", []}])

    {pid, session} = start_tui(sid)

    # The session's own window, the first listed: a line there is input to its agent.
    eventually(fn -> Troupe.UI.TUI.Model.session_window(user_state(pid).model) end)
    press(pid, "1")
    eventually(fn -> user_state(pid).focus == {:window, "root"} end)
    type(pid, "count them")
    press(pid, "enter")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Wake it anyway? [w]")) end, 15_000)
    assert hd(notices(pid)) =~ "cannot start from this session's log"
    assert screen_text(pid, session) =~ "Wake it anyway? [w]"

    press(pid, "w")
    eventually(fn -> hd(notices(pid)) == "Woken past 1 event it could not read" end, 15_000)

    events = Troupe.replay_from(sid, 0)
    assert [%{data: %{"event" => ^poison}}] = Enum.filter(events, &(&1.type == "log_repaired"))
    assert :ok = Troupe.Protocol.Event.verify(events)

    eventually(
      fn ->
        Enum.any?(
          Troupe.replay_from(sid, 0),
          &(&1.type == "user_input" and &1.data["text"] == "count them")
        )
      end,
      15_000
    )

    eventually(fn -> screen_text(pid, session) =~ "could not be read and was skipped" end, 15_000)
  end

  @tag :capture_log
  test "a headless message that cannot wake it names --repair, and --repair wakes it" do
    {sid, ws, poison} =
      unreadable([{:text_and_tools, "Hello.", []}, {:text_and_tools, "Counted.", []}])

    {:ok, io} = StringIO.open("")

    {code, said} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Runner.one_turn(sid, "count them", io) end)

    assert code == 1
    assert said =~ "Protocol.UndefinedError"
    assert said =~ "troupe resume #{sid} --repair wakes it past what its agent cannot read"

    {:ok, args} =
      Troupe.CLI.parse(["resume", sid, "--repair", "--headless", "count them", "--workspace", ws])

    assert args.repair

    assert {:ok, [^poison]} = Troupe.Client.repair(sid)
  end
end
