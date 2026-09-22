defmodule Troupe.GoalClientTest do
  @moduledoc """
  The session's goal from the client's side (issue #59). `/goal` sets, shows and clears it
  through the daemon's `session.goal.*` methods; the goal itself is the daemon's, written
  as `goal_set` and `goal_cleared` and read into every later prompt. The status line shows
  what those events say, so the goal is back on screen whenever the model is rebuilt from
  the session's journal.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.UI.TUI.Model

  test "the client sets, reads and clears the goal, and each change arrives as an event" do
    {sid, _, _} = start_session!(script: [])
    assert {:ok, nil} = Client.goal(sid)

    assert :ok = Client.set_goal(sid, "ship the release notes")
    set = await_event("root", :goal_set)
    assert set.data.text == "ship the release notes"
    assert {:ok, "ship the release notes"} = Client.goal(sid)

    assert :ok = Client.clear_goal(sid)
    await_event("root", :goal_cleared)
    assert {:ok, nil} = Client.goal(sid)
  end

  test "/goal sets it and the status line shows it; /goal shows it; /goal clear takes it off" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/goal ship the release notes")
    press(pid, "enter")
    await_event("root", :goal_set)
    eventually(fn -> status_line(pid, session, sid) =~ "goal: ship the release notes" end)

    # Asked for, it is also the notice at the end of the same line.
    type(pid, "/goal")
    press(pid, "enter")

    eventually(fn -> count(status_line(pid, session, sid), "goal: ship the release notes") == 2 end)

    type(pid, "/goal clear")
    press(pid, "enter")
    await_event("root", :goal_cleared)
    eventually(fn -> status_line(pid, session, sid) =~ "goal cleared" end)
    refute status_line(pid, session, sid) =~ "ship the release notes"
  end

  test "the goal comes back with the screen, because it is folded from the journal" do
    {sid, _, ws} = start_session!(script: [])
    :ok = Client.set_goal(sid, "ship the release notes")
    await_event("root", :goal_set)

    model = Model.rebuild(sid, ws, Client.events(sid))
    assert Model.goal(model) == "ship the release notes"

    :ok = Client.clear_goal(sid)
    await_event("root", :goal_cleared)
    assert Model.goal(Model.rebuild(sid, ws, Client.events(sid))) == nil
  end

  # The status line is the one row that names the session.
  defp status_line(pid, session, sid) do
    pid |> screen(session) |> Enum.find("", &String.contains?(&1, sid))
  end

  defp count(line, text), do: length(String.split(line, text)) - 1
end
