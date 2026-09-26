defmodule Troupe.LoopClientTest do
  @moduledoc """
  A loop towards the goal from the client's side (issue #59). `/loop [n]` starts one and
  `/loop stop` stops it through the daemon's `session.loop.*`; the loop is the daemon's,
  and the window follows its `loop_*` events: the transcript says each iteration and how
  the loop ended, and the status line shows where a running loop is while the input box
  stays the person's. The status line is read back from the screen, so it is also what
  comes back when the model is rebuilt from the session's journal.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.UI.TUI.Model

  defp with_goal(sid) do
    :ok = Client.set_goal(sid, "the notes exist")
    await_event("root", :goal_set)
    sid
  end

  test "the client starts a loop, its iterations arrive as events, and it reads how the loop ended" do
    {sid, _, ws} =
      start_session!(
        script: [
          {:text, "made a start"},
          {:tools, [{"goal_complete", %{"summary" => "notes.md is there"}}]},
          {:text, "the goal is met"}
        ]
      )

    with_goal(sid)
    assert {:ok, nil} = Client.loop(sid)

    assert :ok = Client.start_loop(sid, 3)
    assert %{data: %{max_iterations: 3}} = await_event("root", :loop_started)
    assert %{data: %{iteration: 1}} = await_event("root", :loop_iteration)

    stopped = await_event("root", :loop_stopped, 10_000)
    assert stopped.data.reason == "goal_complete"
    assert stopped.data.summary == "notes.md is there"

    assert {:ok, %{"state" => "stopped", "reason" => "goal_complete", "iteration" => 2}} =
             Client.loop(sid)

    # The window is a fold over the journal: rebuilt, it says how the loop ended and shows
    # no loop running.
    model = Model.rebuild(sid, ws, Client.events(sid))
    assert Model.loop(model) == nil
  end

  test "/loop without a goal says to set one and starts nothing; /loop stop says nothing runs" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/loop")
    press(pid, "enter")

    eventually(fn ->
      status_line(pid, session, sid) =~ "no goal to loop towards; /goal <text> sets one"
    end)

    assert {:ok, nil} = Client.loop(sid)

    type(pid, "/loop stop")
    press(pid, "enter")
    eventually(fn -> status_line(pid, session, sid) =~ "no loop is running" end)
  end

  test "/loop runs while the input box stays free: the status line says where it is, and /loop stop stops it" do
    # The first iteration writes a file and waits for a person to allow it, which keeps
    # the loop running for as long as the test needs to look at it.
    {sid, _, _} =
      start_session!(
        auto_approve: false,
        script: [{:tools, [{"write_file", %{"path" => "notes.md", "content" => "notes"}}]}]
      )

    with_goal(sid)
    {pid, session} = start_tui(sid)

    type(pid, "/loop 2")
    press(pid, "enter")
    await_event("root", :loop_iteration)
    await_event("root", :approval_requested)
    eventually(fn -> status_line(pid, session, sid) =~ "loop 1/2" end)

    # Typed while the loop runs: the command box is the person's throughout.
    type(pid, "/loop stop")
    press(pid, "enter")

    assert %{data: %{reason: "requested"}} = await_event("root", :loop_stopped, 10_000)
    eventually(fn -> not (status_line(pid, session, sid) =~ "loop 1/2") end)

    eventually(fn ->
      screen_text(pid, session) =~ "loop stopped after 1 iteration: stopped on request"
    end)
  end

  describe "after the daemon stopped mid-loop" do
    # A daemon that dies writes nothing more: the log still says the loop runs, and the
    # `loop_stopped interrupted` a restore records is written only when the session is
    # next activated. The screen asks the session, which knows its tree is not running.
    setup do
      {sid, _, _} =
        start_session!(
          auto_approve: false,
          script: [{:tools, [{"write_file", %{"path" => "notes.md", "content" => "notes"}}]}]
        )

      with_goal(sid)
      :ok = Client.start_loop(sid, 2)
      await_event("root", :loop_iteration)
      await_event("root", :approval_requested)
      %{sid: sid}
    end

    test "a screen opened on the session shows no loop running", %{sid: sid} do
      crash(sid)
      {pid, session} = start_tui(sid)

      eventually(fn ->
        line = status_line(pid, session, sid)
        line =~ "goal: the notes exist" and not (line =~ "loop 1/2")
      end)

      # The transcript still says what ran before the daemon stopped.
      assert screen_text(pid, session) =~ "loop iteration 1/2"
    end

    test "a screen open through it asks again when its connection says so", %{sid: sid} do
      {pid, session} = start_tui(sid)
      eventually(fn -> status_line(pid, session, sid) =~ "loop 1/2" end)

      crash(sid)
      send(pid, {:troupe_event, status_event(sid, %{up?: true})})

      eventually(fn ->
        line = status_line(pid, session, sid)
        line =~ "goal: the notes exist" and not (line =~ "loop 1/2")
      end)
    end
  end

  # What a crash leaves: the session's tree gone, and nothing in its log about it, not
  # even the `session_dormant` that stopping it properly writes.
  defp crash(sid) do
    :ok = Troupe.Sessions.stop_session(sid)
    assert {:ok, %{"state" => "stopped", "reason" => "interrupted"}} = Client.loop(sid)
  end

  # What the worker publishes when its connection comes up.
  defp status_event(sid, data) do
    %Troupe.Event{
      session_id: sid,
      agent_path: "root",
      type: :remote_status,
      ts: System.system_time(:millisecond),
      data: data
    }
  end

  # The status line is the one row that names the session.
  defp status_line(pid, session, sid) do
    pid |> screen(session) |> Enum.find("", &String.contains?(&1, sid))
  end
end
