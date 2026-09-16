defmodule Troupe.SessionPickerTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Session
  alias Troupe.Session.Index

  # Decision 65
  describe "Troupe.Session.Index" do
    test "summarises the sessions of one workspace and ignores every other one" do
      ws = tmp_workspace() |> git_init!()
      other = tmp_workspace() |> git_init!()

      {sid, _fake, _} =
        start_session!(
          workspace: ws,
          scripts: %{"code-1" => [{:finish, "fixed it"}]},
          auto_approve: true
        )

      {other_sid, _fake, _} = start_session!(workspace: other)

      {:ok, "code-1"} = Troupe.dispatch(sid, "code", "fix the failing dispatcher test")
      await_state("code-1", :done_unread)

      [entry] = Index.list(ws)

      assert entry.session_id == sid
      assert entry.workspace == ws
      assert entry.title == "fix the failing dispatcher test"
      assert entry.running?
      assert entry.closed_at == nil
      assert entry.created_at <= System.system_time(:millisecond)
      assert entry.updated_at != nil

      assert [%{path: "code-1", name: "code", state: :done_unread, prompt: prompt}] =
               Index.live_branches(entry)

      assert prompt == "fix the failing dispatcher test"

      # the other workspace's session is not in this workspace's list, and vice versa
      refute Enum.any?(Index.list(ws), &(&1.session_id == other_sid))
      assert [%{session_id: ^other_sid, branches: []}] = Index.list(other)
    end

    test "a dismissed branch stays out of the live ones, and a stopped session is still listed" do
      ws = tmp_workspace() |> git_init!()

      {sid, _fake, _} =
        start_session!(
          workspace: ws,
          scripts: %{"code-1" => [{:finish, "one"}], "code-2" => [{:finish, "two"}]},
          auto_approve: true
        )

      {:ok, "code-1"} = Troupe.dispatch(sid, "code", "first task")
      {:ok, "code-2"} = Troupe.dispatch(sid, "code", "second task")
      await_state("code-1", :done_unread)
      await_state("code-2", :done_unread)
      :ok = Troupe.dismiss(sid, "code-2")

      :ok = Troupe.stop_session(sid)
      eventually(fn -> Session.whereis(sid, :session) == nil end)

      [entry] = Index.list(ws)
      refute entry.running?
      assert length(entry.branches) == 2
      assert [%{path: "code-1"}] = Index.live_branches(entry)
      assert entry.title == "first task"
    end
  end

  describe "/resume in the TUI" do
    test "lists this directory's sessions and switches the window to the one picked" do
      ws = tmp_workspace() |> git_init!()

      # a session that did some work, then stopped: this is what the picker offers
      {done, _fake, _} =
        start_session!(
          workspace: ws,
          scripts: %{"code-1" => [{:finish, "shipped the parser"}]},
          auto_approve: true
        )

      {:ok, "code-1"} = Troupe.dispatch(done, "code", "write the parser")
      await_state("code-1", :done_unread)
      :ok = Troupe.stop_session(done)
      eventually(fn -> Session.whereis(done, :session) == nil end)

      # the session the TUI is opened on, with a branch of its own
      {live, _fake, _} =
        start_session!(
          workspace: ws,
          scripts: %{"code-1" => [{:finish, "reviewed it"}]},
          auto_approve: true
        )

      {:ok, "code-1"} = Troupe.dispatch(live, "code", "review the parser")
      await_state("code-1", :done_unread)

      {pid, session} = start_tui(live)
      eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

      type(pid, "resume")
      press(pid, "enter")

      assert user_state(pid).focus == :sessions
      text = screen_text(pid, session)
      assert text =~ "2 session(s)"
      assert text =~ "write the parser"
      assert text =~ "review the parser"
      assert text =~ "1 branch"
      assert text =~ "1 done"
      assert text =~ "Enter resumes"

      # newest first, and the cursor starts on the session already on screen
      state = user_state(pid)
      assert Enum.map(state.sessions.entries, & &1.session_id) == [live, done]
      assert state.sessions.cursor == 0

      press(pid, "down")
      assert user_state(pid).sessions.cursor == 1

      detail = screen_text(pid, session)
      assert detail =~ done
      assert detail =~ "Enter replays it"

      press(pid, "enter")

      eventually(fn -> user_state(pid).session_id == done end)
      state = user_state(pid)
      assert state.focus == :command
      assert state.sessions == nil
      assert state.model.session_id == done
      assert state.model.workspace == ws
      # the window comes back from the other log, with the prompt that branch was given
      assert %{state: :done_unread, summary: "shipped the parser"} = state.model.windows["code-1"]
      assert Session.whereis(done, :session) != nil

      text = screen_text(pid, session)
      assert text =~ done
      assert text =~ "resumed #{done}"
      refute text =~ live

      # the session left behind keeps running (it has a branch), and its events no
      # longer touch this window
      assert Session.whereis(live, :session) != nil

      Troupe.Events.publish(%Troupe.Event{
        session_id: live,
        agent_path: "code-1",
        type: :notice,
        data: %{text: "from the session we left"},
        ts: System.system_time(:millisecond)
      })

      eventually(fn -> user_state(pid).session_id == done end)
      refute screen_text(pid, session) =~ "from the session we left"
    end

    test "an empty session is retired when you switch away from it" do
      ws = tmp_workspace() |> git_init!()

      {done, _fake, _} =
        start_session!(
          workspace: ws,
          scripts: %{"code-1" => [{:finish, "done"}]},
          auto_approve: true
        )

      {:ok, "code-1"} = Troupe.dispatch(done, "code", "the only task")
      await_state("code-1", :done_unread)

      # what `troupe` opens for you: a session with nothing in it
      {scratch, _fake, _} = start_session!(workspace: ws)
      {pid, session} = start_tui(scratch)

      type(pid, "resume ")
      type(pid, done)
      press(pid, "enter")

      eventually(fn -> user_state(pid).session_id == done end)
      eventually(fn -> Session.whereis(scratch, :session) == nil end)

      assert screen_text(pid, session) =~ "the only task"
    end

    test "/resume takes a row number, reports an id that is not here, and Esc backs out" do
      ws = tmp_workspace() |> git_init!()

      {sid, _fake, _} =
        start_session!(
          workspace: ws,
          scripts: %{"code-1" => [{:finish, "done"}]},
          auto_approve: true
        )

      {:ok, "code-1"} = Troupe.dispatch(sid, "code", "the task")
      await_state("code-1", :done_unread)

      {pid, session} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

      type(pid, "resume nope-nope")
      press(pid, "enter")
      assert user_state(pid).focus == :command
      assert screen_text(pid, session) =~ "no session here matching nope-nope"

      # row 1 is this session: switching to it is a no-op, not a restart
      type(pid, "resume 1")
      press(pid, "enter")
      assert user_state(pid).session_id == sid
      assert screen_text(pid, session) =~ "already in this session"

      type(pid, "sessions")
      press(pid, "enter")
      assert user_state(pid).focus == :sessions
      press(pid, "r")
      assert user_state(pid).focus == :sessions
      press(pid, "esc")
      assert user_state(pid).focus == :command
      assert user_state(pid).sessions == nil
    end

    test "the picker opens straight away when the TUI is started on it" do
      ws = tmp_workspace() |> git_init!()
      {sid, _fake, _} = start_session!(workspace: ws)
      {pid, session} = start_tui(sid, page: :sessions)

      assert user_state(pid).focus == :sessions
      text = screen_text(pid, session)
      assert text =~ "1 session(s)"
      assert text =~ "(no branches)"
      assert text =~ "No branches yet."
    end
  end
end
