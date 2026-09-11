defmodule Troupe.CloseSessionTest do
  @moduledoc """
  `Dispatcher.close/2` and `finished?/1`. The branch that introduced them ran out
  of budget before writing `report/1`, `blockers/2` and the `:finished?` clause,
  so these cover the semantics those three settled.
  """
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Paths
  alias Troupe.Session.{Dispatcher, Log}

  test "a fresh session is not finished and closes with an empty report" do
    {sid, _fake, _ws} = start_session!()

    refute Dispatcher.finished?(sid)

    assert {:ok, report} = Dispatcher.close(sid)
    assert report.session_id == sid
    assert report.branches == 0
    assert report.active == []
    assert report.worktrees == []
    assert report.text == "no branches ran"
  end

  test "closing counts a finished branch and writes session_closed plus closed_at" do
    {sid, _fake, ws} = start_session!(script: [{:finish, "ok"}])

    {:ok, path} = Troupe.dispatch(sid, "code", "task")
    await_state(path, :done_unread)

    assert Dispatcher.finished?(sid)
    assert {:ok, report} = Dispatcher.close(sid)
    assert %{branches: 1, done: 1, failed: 0, active: [], worktrees: []} = report
    assert report.text == "1 branch(es): 1 done, 0 failed"

    assert [event] = events_of(sid, "session", :session_closed)
    assert event.data.branches == 1
    assert event.data.done == 1
    refute event.data.forced

    meta = Path.join(Paths.session_dir(ws, sid), "meta.json")
    assert {:ok, %{closed_at: closed_at}} = Log.read_meta(meta)
    assert is_integer(closed_at)
  end

  test "an active branch blocks the close until it is forced" do
    fallback = fn req ->
      if length(req.messages) < 3,
        do: {:tool, "shell", %{"command" => "sleep 5"}},
        else: {:finish, "ok"}
    end

    {sid, _fake, _ws} = start_session!(fallback: fallback, auto_approve: true)

    {:ok, path} = Troupe.dispatch(sid, "code", "task")
    eventually(fn -> window(sid, path).state in [:running, :needs_input] end)

    refute Dispatcher.finished?(sid)
    assert {:error, msg} = Dispatcher.close(sid)
    assert msg =~ "1 branch(es) still active: #{path}"
    assert msg =~ "use force to close anyway"
    assert events_of(sid, "session", :session_closed) == []

    assert {:ok, report} = Dispatcher.close(sid, true)
    assert report.active == [path]
    assert report.text =~ "1 active"

    assert [event] = events_of(sid, "session", :session_closed)
    assert event.data.forced
  end

  test "the counts survive dismissal" do
    {sid, _fake, _ws} = start_session!(script: [{:finish, "ok"}])

    {:ok, path} = Troupe.dispatch(sid, "code", "task")
    await_state(path, :done_unread)
    :ok = Dispatcher.dismiss(sid, path)
    eventually(fn -> window(sid, path).state == :dismissed end)

    assert {:ok, %{branches: 1, done: 1}} = Dispatcher.close(sid)
  end

  test "a worktree that is neither merged nor discarded blocks the close" do
    ws = git_init!(tmp_workspace())
    {sid, _fake, _ws} = start_session!(workspace: ws, script: [{:finish, "ok"}])

    {:ok, path} = Troupe.dispatch(sid, "worktree", "task")
    await_state(path, :done_unread)

    assert Dispatcher.finished?(sid)
    assert {:error, msg} = Dispatcher.close(sid)
    assert msg =~ "1 worktree(s) neither merged nor discarded: #{path}"

    {:ok, _} = Dispatcher.discard(sid, path)
    assert {:ok, report} = Dispatcher.close(sid)
    assert report.worktrees == []
  end
end
