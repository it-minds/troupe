defmodule Troupe.BranchCommandsTest do
  @moduledoc """
  The branch commands since a branch became a session of its own (Decision 103), held to
  their rows in `Troupe.Commands` and the TUI decisions that made them, where the command
  audit of #502 found them short (root Decision 843): `/cancel` and `x x` (TUI Decision
  57), `/worktree <name>:` and `/worktree <existing>` with Tab (TUI Decisions 39 and 42),
  a dismissed branch in `/sessions`, what `/merge` says when git refuses it or cannot
  remove the tree, and `/dismiss` of a session's own window. Everything runs against the
  embedded daemon, and a pod's session against the suite's `FakeRemote`.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.UI.TUI.Model

  @moduletag timeout: 120_000

  # A branch reads the workspace's `.troupe/config.yaml` from its own worktree, so the
  # fake's configuration is committed for the branch to see it.
  defp repo_with_fake!(script) do
    ws = git_init!(tmp_workspace())
    {sid, _, ^ws} = start_session!(workspace: ws, script: script)
    run_git!(ws, ["add", "-A"])
    run_git!(ws, ["commit", "-q", "-m", "fake model"])
    on_exit(fn -> remove_siblings(ws) end)
    {sid, ws}
  end

  # The worktrees a test made beside its repository, which outlive the repository's own
  # directory.
  defp remove_siblings(ws) do
    for dir <- Path.wildcard(ws <> "-*") do
      File.chmod(Path.join(dir, "locked"), 0o755)
      File.rm_rf(dir)
    end
  end

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {pid, session}
  end

  defp enter(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  defp line(pid), do: user_state(pid).cmd_text

  defp notices(pid), do: user_state(pid).model.notices

  defp await_notice(pid, before) do
    eventually(fn -> notices(pid) != before end, 15_000)
    hd(notices(pid))
  end

  defp await_finished(pid, window) do
    eventually(
      fn -> match?(%{state: :done_unread}, user_state(pid).model.windows[window]) end,
      15_000
    )
  end

  defp digit(pid, window) do
    index = Enum.find_index(Model.windows(user_state(pid).model), &(&1.path == window))
    Integer.to_string(index + 1)
  end

  describe "/cancel and x x (TUI Decision 57)" do
    # The row: stops the agent "and removes the window; a worktree Troupe made for it goes
    # too". The worktree goes once the branch is at rest, so nothing is writing it then.
    test "a running branch's turn is cancelled, and then its worktree and its window go" do
      {sid, _ws} =
        repo_with_fake!([{:tool, "shell", %{"command" => "sleep 30"}}, {:finish, "slept"}])

      {pid, _session} = ready(sid)

      for how <- [:command, :keys] do
        assert {:ok, window} = Client.dispatch(sid, "build", "sleep")
        worktree = await_event(window, :worktree_created).data.path
        assert %{data: %{name: "shell"}} = await_event(window, :tool_started, 15_000)

        case how do
          :command ->
            enter(pid, "/cancel #{window}")

          :keys ->
            press(pid, digit(pid, window))
            assert user_state(pid).focus == {:window, window}
            press(pid, "x")
            press(pid, "x")
        end

        await_event(window, :worktree_discarded, 15_000)
        await_event(window, :window_dismissed)
        refute File.dir?(worktree), "#{how}: the worktree Troupe made is gone"
        refute Map.has_key?(user_state(pid).model.windows, window)
      end
    end
  end

  describe "/worktree (TUI Decisions 39 and 42)" do
    test "<name>: works in a Troupe worktree of that name, made the first time and the same one after" do
      {sid, ws} = repo_with_fake!([{:text, "done"}])
      {pid, _session} = ready(sid)

      enter(pid, "/worktree login: say done")
      created = await_event("worktree-1", :worktree_created)
      assert created.data.git_branch == "troupe/login"
      assert Path.basename(created.data.path) == Path.basename(ws) <> "-login"
      assert await_event("worktree-1", :input).data.content == "say done"
      await_finished(pid, "worktree-1")

      enter(pid, "/worktree login: and again")
      again = await_event("worktree-2", :worktree_created)
      assert again.data.path == created.data.path
      assert await_event("worktree-2", :input).data.content == "and again"
    end

    test "<existing> works in a worktree the person checked out, and leaves it theirs" do
      {sid, ws} = repo_with_fake!([{:text, "done"}])
      mine = Path.join(Path.dirname(ws), Path.basename(ws) <> "-mine")
      run_git!(ws, ["worktree", "add", "-q", "-b", "feature", mine])
      {pid, _session} = ready(sid)

      enter(pid, "/worktree feature say done")
      spawned = await_event("worktree-1", :branch_spawned)
      assert Path.expand(spawned.data.worktree) == Path.expand(mine)
      assert await_event("worktree-1", :input).data.content == "say done"
      await_finished(pid, "worktree-1")

      for verb <- ["merge", "discard"] do
        before = notices(pid)
        enter(pid, "/#{verb} worktree-1")
        assert await_notice(pid, before) =~ "your own worktree"
      end

      assert File.dir?(mine)
      assert Map.has_key?(user_state(pid).model.windows, "worktree-1")
    end

    test "Tab offers the worktrees checked out and Troupe's by name, never the checkout itself" do
      {sid, ws} = repo_with_fake!([{:text, "done"}])
      mine = Path.join(Path.dirname(ws), Path.basename(ws) <> "-mine")
      run_git!(ws, ["worktree", "add", "-q", "-b", "feature", mine])
      assert {:ok, "worktree-1"} = Client.dispatch(sid, "worktree", "login: say done")
      await_event("worktree-1", :worktree_created)
      {pid, _session} = ready(sid)

      paste(pid, "/worktree ")

      offered =
        for _ <- 1..4 do
          press(pid, "tab")
          line(pid)
        end

      assert Enum.uniq(offered) == [
               "/worktree feature ",
               "/worktree login: ",
               "/worktree #{Path.basename(mine)} "
             ]
    end
  end

  describe "/sessions" do
    # The row of /dismiss: a branch's session "stays in the daemon, where /sessions still
    # lists it".
    test "a dismissed branch is listed, and /resume goes to it" do
      {sid, _ws} = repo_with_fake!([{:text, "done"}])
      {pid, _session} = ready(sid)

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say done")
      child = await_event("build-1", :branch_spawned).data.session_id
      on_exit(fn -> Client.stop_session(child) end)
      await_finished(pid, "build-1")

      enter(pid, "/dismiss build-1")
      await_event("build-1", :window_dismissed)

      enter(pid, "/sessions")
      eventually(fn -> user_state(pid).focus == :sessions end)
      assert child in Enum.map(user_state(pid).sessions.entries, & &1.id)
      press(pid, "esc")

      enter(pid, "/resume #{child}")
      eventually(fn -> user_state(pid).session_id == child end)
    end
  end

  describe "/merge" do
    # git refuses a merge that would overwrite what the person has not committed: nothing
    # conflicted, and there is nothing to resolve.
    test "one git refuses for the checkout's own changes says so, and keeps the window" do
      script = [
        {:tool, "write_file", %{"path" => "notes.txt", "content" => "from the branch\n"}},
        {:finish, "wrote notes.txt"}
      ]

      {sid, ws} = repo_with_fake!(script)
      {pid, _session} = ready(sid)
      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "write the notes")
      await_finished(pid, "build-1")
      File.write!(Path.join(ws, "notes.txt"), "the person's, not committed\n")

      before = notices(pid)
      enter(pid, "/merge build-1")
      said = await_notice(pid, before)

      assert said =~ "not merged"
      assert said =~ "uncommitted"
      refute said =~ "conflict"
      assert File.read!(Path.join(ws, "notes.txt")) == "the person's, not committed\n"
      assert Map.has_key?(user_state(pid).model.windows, "build-1")
    end

    # On Windows a tree git cannot delete is an everyday thing (a file an editor holds);
    # here a directory git may not write stands in for it.
    test "one that landed but whose worktree could not be removed says both" do
      script = [
        {:tool, "write_file", %{"path" => "locked/kept.txt", "content" => "landed\n"}},
        {:finish, "wrote it"}
      ]

      {sid, ws} = repo_with_fake!(script)
      {pid, _session} = ready(sid)
      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "write it")
      worktree = await_event("build-1", :worktree_created).data.path
      await_finished(pid, "build-1")
      File.chmod!(Path.join(worktree, "locked"), 0o555)

      before = notices(pid)
      enter(pid, "/merge build-1")
      said = await_notice(pid, before)

      assert said =~ ~r/^merged troupe\/\S+ into the checkout/
      assert said =~ "could not be removed"
      assert File.read!(Path.join(ws, "locked/kept.txt")) == "landed\n"
    end
  end

  describe "/dismiss of a session's own window" do
    test "keeps the screen on a session of this machine, and says how to leave it" do
      {sid, _, _} = start_session!(script: [])
      {pid, _session} = ready(sid)
      eventually(fn -> user_state(pid).model.windows != %{} end)

      before = notices(pid)
      enter(pid, "/dismiss 1")
      assert await_notice(pid, before) =~ "own window"
      assert Client.has_session?(sid)
      assert user_state(pid).session_id == sid
    end

    @tag :remote
    test "keeps a pod session's screen speaking to the pod" do
      session =
        FakeRemote.session(
          id: "s-pod",
          profile: "build",
          title: "on a pod",
          events: [%{"type" => "message.completed", "data" => %{"text" => "first line"}}]
        )

      {remote, url} = start_remote!(sessions: [session])
      sid = attach!(connect!(remote, url), "s-pod")
      {pid, _session} = ready(sid)
      eventually(fn -> user_state(pid).model.windows != %{} end)

      before = notices(pid)
      enter(pid, "/dismiss 1")
      assert await_notice(pid, before) =~ "own window"
      assert Client.remote?(sid)

      enter(pid, "/goal")

      eventually(fn ->
        Enum.any?(FakeRemote.calls(remote), &match?({"session.goal.get", _}, &1))
      end)
    end
  end
end
