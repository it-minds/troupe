defmodule Troupe.CommandSeamsTest do
  @moduledoc """
  Command mode's seams after #556 and #560 (D113, and what D105 and D107 left), TUI
  Decision 158: an approval a branch asked before its worker connection restarted, answered
  from the parent's screen; `/new --branch` with the work in the branches; what the screen
  says after a merge that conflicted; where the focus is once a window the palette closed
  has gone; what a branch's row and a dismissed branch's picker row say. Everything runs
  against the embedded daemon.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Remote.{Translate, Worker}
  alias Troupe.UI.TUI.Model

  @moduletag timeout: 120_000

  # A branch reads the workspace's `.troupe/config.yaml` from its own worktree, so the
  # fake's configuration is committed for the branch to see it.
  defp repo_with_fake!(script, opts \\ []) do
    ws = git_init!(tmp_workspace())
    {sid, _, ^ws} = start_session!([workspace: ws, script: script] ++ opts)
    run_git!(ws, ["add", "-A"])
    run_git!(ws, ["commit", "-q", "-m", "fake model"])
    on_exit(fn -> remove_siblings(ws) end)
    {sid, ws}
  end

  # The worktrees a test made beside its repository, which outlive the repository's own
  # directory.
  defp remove_siblings(ws), do: for(dir <- Path.wildcard(ws <> "-*"), do: File.rm_rf(dir))

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {pid, session}
  end

  defp window(pid, path), do: user_state(pid).model.windows[path]

  defp digit(pid, path) do
    index = Enum.find_index(Model.windows(user_state(pid).model), &(&1.path == path))
    Integer.to_string(index + 1)
  end

  describe "an approval a branch asked before its worker restarted (D113)" do
    # `Client.Daemon.call_target/2` found the branch by a registration its worker made as
    # the request went by, and that died with the worker. A worker that starts again
    # resumes past the request, so nothing made it again: `y` on the parent's screen went to
    # the parent's own session, and the branch waited for ever.
    test "is answered from the parent's screen, and reaches the branch" do
      script = [
        {:tool, "write_file", %{"path" => "gated.txt", "content" => "approved\n"}},
        {:finish, "wrote it"}
      ]

      {sid, _ws} = repo_with_fake!(script, auto_approve: false)
      {pid, _session} = ready(sid)

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "write the gated file")
      child = await_event("build-1", :branch_spawned).data.session_id
      worktree = await_event("build-1", :worktree_created).data.path
      await_event("build-1", :approval_requested, 15_000)
      eventually(fn -> match?(%{state: :needs_input}, window(pid, "build-1")) end, 10_000)

      # The branch's connection goes, and its supervisor starts it again.
      old = Worker.whereis(child)
      Process.exit(old, :kill)
      eventually(fn -> Worker.whereis(child) not in [nil, old] end)
      eventually(fn -> Worker.status(child).up? end, 10_000)

      press(pid, digit(pid, "build-1"))
      assert user_state(pid).focus == {:window, "build-1"}
      press(pid, "y")

      await_event("build-1", :approval_answered, 15_000)

      eventually(
        fn -> File.read(Path.join(worktree, "gated.txt")) == {:ok, "approved\n"} end,
        15_000
      )
    end

    # The budget question is drawn from `budget_ask_started`, which the registration never
    # took, so a branch's went to the parent's session whether its worker restarted or not.
    test "a branch's budget question is answered from the parent's screen too" do
      script = [{:tools, [{"todo_read", %{}}]}, {:tools, [{"todo_read", %{}}]}, {:text, "done"}]
      {sid, _ws} = repo_with_fake!(script, config: %{"max_turns" => 1})
      {pid, _session} = ready(sid)

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "go")

      eventually(
        fn ->
          match?(%{pending: [%{kind: :budget, options: [_ | _]} | _]}, window(pid, "build-1"))
        end,
        15_000
      )

      press(pid, digit(pid, "build-1"))
      press(pid, "1")

      assert %{data: %{decision: "raise"}} = await_event("build-1", :budget_ask_answered, 15_000)
    end
  end

  describe "/new --branch in command mode" do
    # The session's own log holds no conversation in command mode: the work is in its
    # branches. Forking it gave an empty session, said as though it were the work.
    test "forks the branch whose window is activated, and otherwise says which it needs" do
      {sid, _ws} = repo_with_fake!([{:text, "hello from the branch"}])
      {pid, _session} = ready(sid)

      before = notices(pid)
      enter(pid, "/new --branch")
      assert await_notice(pid, before) =~ "nothing to fork: no branch has started"
      assert user_state(pid).session_id == sid

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say hello")
      child = await_event("build-1", :branch_spawned).data.session_id
      on_exit(fn -> Client.stop_session(child) end)
      await_finished(pid, "build-1")

      before = notices(pid)
      enter(pid, "/new --branch")
      said = await_notice(pid, before)
      assert said =~ "/new --branch forks a branch: open its window (1 build-1)"
      assert said =~ "own log holds no conversation"
      assert user_state(pid).session_id == sid

      # Typed in the branch's window, it forks the branch: the new session's log is the
      # branch's conversation, and `/back` returns to the session it came from.
      press(pid, digit(pid, "build-1"))
      assert user_state(pid).focus == {:window, "build-1"}
      paste(pid, "/new --branch")
      press(pid, "enter")

      eventually(fn -> user_state(pid).session_id not in [sid, child] end, 10_000)
      fork = user_state(pid).session_id
      on_exit(fn -> Client.stop_session(fork) end)
      assert user_state(pid).back == sid

      eventually(fn ->
        Enum.any?(
          Client.events(fork),
          &(&1.type == :assistant_message and inspect(&1.data) =~ "hello from the branch")
        )
      end)
    end
  end

  describe "/merge of a branch that conflicts with the checkout" do
    # The daemon aborts such a merge and leaves the checkout as it was (Decision 647):
    # there is nothing in the checkout to resolve, and the branch is merged by hand.
    test "says the merge was aborted and the branch is to be merged by hand" do
      script = [
        {:tool, "write_file", %{"path" => "notes.txt", "content" => "from the branch\n"}},
        {:finish, "wrote notes.txt"}
      ]

      {sid, ws} = repo_with_fake!(script)
      {pid, session} = ready(sid)
      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "write the notes")
      branch = await_event("build-1", :worktree_created).data.git_branch
      await_finished(pid, "build-1")

      File.write!(Path.join(ws, "notes.txt"), "from the checkout\n")
      run_git!(ws, ["add", "notes.txt"])
      run_git!(ws, ["commit", "-q", "-m", "the checkout's notes"])

      before = notices(pid)
      enter(pid, "/merge build-1")
      said = await_notice(pid, before)

      assert said =~ "build-1 is not merged"
      assert said =~ "the merge was aborted and the checkout is as it was"
      assert said =~ "merge #{branch} by hand"
      refute said =~ "resolve in your checkout"
      assert File.read!(Path.join(ws, "notes.txt")) == "from the checkout\n"
      assert window(pid, "build-1")

      press(pid, digit(pid, "build-1"))
      text = screen_text(pid, session)
      assert text =~ "merge aborted"
      refute text =~ "resolve in your checkout"
    end
  end

  describe "the focus after a window command from the palette (D105)" do
    test "/merge, /discard and /dismiss leave the screen on the command line" do
      {sid, _ws} = repo_with_fake!([{:text, "done"}])
      {pid, _session} = ready(sid)

      for name <- ["merge", "discard", "dismiss"] do
        assert {:ok, path} = Client.dispatch(sid, "build", "say done")
        await_finished(pid, path)

        press(pid, digit(pid, path))
        assert user_state(pid).focus == {:window, path}
        press(pid, "k", ["ctrl"])
        type(pid, name)
        press(pid, "enter")

        await_event(path, :window_dismissed, 10_000)
        eventually(fn -> user_state(pid).focus == :command end)
        refute window(pid, path)
      end
    end
  end

  describe "what the screen says" do
    # quick's model is the cheap one; a branch's row said only its agent.
    test "a branch's row names the model it runs" do
      {sid, _ws} =
        repo_with_fake!([{:text, "done"}],
          config: %{"models" => %{"default" => "fake-model", "cheap" => "fake-small"}}
        )

      {pid, session} = ready(sid)

      assert {:ok, "quick-1"} = Client.dispatch(sid, "quick", "say done")
      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say done")
      await_finished(pid, "quick-1")
      await_finished(pid, "build-1")

      eventually(fn ->
        rows = screen(pid, session)

        Enum.any?(rows, &(&1 =~ "quick-1" and &1 =~ "fake-small")) and
          Enum.any?(rows, &(&1 =~ "build-1" and &1 =~ "fake-model"))
      end)
    end

    # The daemon's title for a branch's session is the worktree it worked in.
    test "a dismissed branch's picker row is titled by what it was first asked" do
      {sid, _ws} = repo_with_fake!([{:text, "done"}])
      {pid, _session} = ready(sid)

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "tidy the parser")
      assert {:ok, "build-2"} = Client.dispatch(sid, "build", "")
      first = await_event("build-1", :branch_spawned).data.session_id
      second = await_event("build-2", :branch_spawned).data.session_id
      on_exit(fn -> for child <- [first, second], do: Client.stop_session(child) end)
      :ok = Client.send_input(sid, "build-2", "rename the module\nand its tests")
      await_finished(pid, "build-1")
      await_finished(pid, "build-2")

      for path <- ["build-1", "build-2"] do
        enter(pid, "/dismiss #{path}")
        await_event(path, :window_dismissed)
      end

      enter(pid, "/sessions")
      eventually(fn -> user_state(pid).focus == :sessions end)
      titles = Map.new(user_state(pid).sessions.entries, &{&1.id, &1.title})

      assert titles[first] == "build-1, dismissed: tidy the parser"
      assert titles[second] == "build-2, dismissed: rename the module"
    end

    test "a subagent is labelled with its own agent, and read_branch's input is said in words" do
      {sid, _, _} = start_session!(script: [])
      {pid, session} = ready(sid)

      inject(pid, sid, [
        wire("root", "user_input", %{"source" => "user", "text" => "look around"}),
        wire("root", "llm_request", %{"message_count" => 1}),
        wire("root", "tool_call_started", %{
          "call_id" => "call_1",
          "name" => "read_branch",
          "args" => %{"session_id" => "s-7", "diff" => true}
        }),
        wire("root", "tool_call_started", %{
          "call_id" => "call_2",
          "name" => "read_branch",
          "args" => %{}
        }),
        wire("root", "tool_call_started", %{
          "call_id" => "call_3",
          "name" => "delegate",
          "args" => %{"agent" => "explore", "goal" => "find the parser"}
        }),
        wire("root/explore#1", "agent_started", %{"mode" => "subagent", "profile" => "explore"}),
        wire("root", "delegation_started", %{
          "agent" => "explore",
          "call_id" => "call_3",
          "child_path" => ["root", "explore#1"]
        }),
        wire("root/explore#1", "user_input", %{"source" => "user", "text" => "find the parser"})
      ])

      press(pid, digit(pid, "root"))
      assert user_state(pid).focus == {:window, "root"}

      # Quiet keeps the calls to one strip (TUI Decision 161); `e` opens the turn to read them.
      press(pid, "e")
      text = screen_text(pid, session)

      assert text =~ "explore#1 (explore)"
      refute text =~ "explore#1 (build)"
      assert text =~ "s-7, with its diff"
      assert text =~ "the branches"
      refute text =~ ~s({"diff")
    end
  end

  ## Helpers

  defp notices(pid), do: user_state(pid).model.notices

  defp await_notice(pid, before) do
    eventually(fn -> notices(pid) != before end, 15_000)
    hd(notices(pid))
  end

  defp await_finished(pid, path) do
    eventually(fn -> match?(%{state: :done_unread}, window(pid, path)) end, 15_000)
  end

  defp enter(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  defp wire(agent, type, data) do
    %{
      "actor" => %{"kind" => "system"},
      "agent" => String.split(agent, "/"),
      "data" => data,
      "seq" => System.unique_integer([:positive, :monotonic]),
      "ts" => System.system_time(:millisecond),
      "type" => type,
      "v" => 1
    }
  end

  # Straight into the screen's mailbox, translated as a worker publishes them.
  defp inject(pid, sid, wires) do
    {events, _memory} =
      Enum.flat_map_reduce(wires, Translate.memory(:shared), &Translate.durable(sid, &1, &2))

    for event <- events, do: send(pid, {:troupe_event, event})
    _ = user_state(pid)
    :ok
  end
end
