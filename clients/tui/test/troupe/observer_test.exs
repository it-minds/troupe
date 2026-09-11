defmodule Troupe.ObserverTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.UI.TUI.Model

  # Decision 43
  test "/observer shows every agent as a tree, with the selected one's detail" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      # a branch that delegates, then waits for an answer, so the tree has a live subagent
      "code-1" => [
        {:tool, "delegate", %{"agent" => "explore", "prompt" => "look around"}},
        {:tool, "ask_user", %{"question" => "Which database?"}},
        {:finish, "done"}
      ],
      "code-1/explore-1" => [
        {:tool, "list_files", %{"path" => "."}},
        {:finish, "looked around"}
      ],
      "worktree-1" => [
        {:tool, "write_file", %{"path" => "feature.txt", "content" => "x\n"}},
        {:finish, "built the feature"}
      ]
    }

    {sid, _fake, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "investigate then ask")
    {:ok, "worktree-1"} = Troupe.dispatch(sid, "worktree", "feat-auth: build the feature")
    await_state("code-1", :needs_input, 15_000)
    await_state("worktree-1", :done_unread, 15_000)

    eventually(fn ->
      Map.has_key?(user_state(pid).model.windows["code-1"].agents, "code-1/explore-1")
    end)

    press(pid, "o")
    press(pid, "b")
    press(pid, "s")
    type(pid, "erver")
    press(pid, "enter")

    text = screen_text(pid, session)
    assert user_state(pid).focus == :observer

    # the tree: both branches, the subagent nested under its parent, and the totals
    assert text =~ "agents —"
    assert text =~ "3 agents in 2 branches"
    assert text =~ "code-1"
    assert text =~ "↳ explore-1"
    assert text =~ "(explore)"
    assert text =~ "worktree-1"

    # the first row's detail: the branch it belongs to, where it works, its prompt
    assert text =~ "code-1  (code, depth 0)"
    assert text =~ "shared checkout"
    assert text =~ "working in #{ws}"
    assert text =~ "investigate then ask"
    assert text =~ "waiting for you"
    assert text =~ "question: Which database?"

    # the subagent's detail: its own name, depth and tool calls
    press(pid, "down")
    text = screen_text(pid, session)
    assert text =~ "code-1/explore-1  (explore subagent, depth 1)"
    assert text =~ "recent tool calls"
    assert text =~ "✓ list_files"

    # the worktree branch names its worktree and where that worktree lives
    press(pid, "down")
    text = screen_text(pid, session)
    assert text =~ "worktree-1  (worktree, depth 0)"
    assert text =~ "worktree troupe/feat-auth (Troupe-managed)"
    assert text =~ "working in #{Path.join([ws, ".troupe", "worktrees", "feat-auth"])}"
    assert text =~ "built the feature"

    # Enter opens that branch's window; Esc from the observer goes back to the command line
    press(pid, "enter")
    assert user_state(pid).focus == {:window, "worktree-1"}
    assert screen_text(pid, session) =~ "worktree-1 (worktree) — Esc back"

    press(pid, "esc")
    type(pid, "observer")
    press(pid, "enter")
    press(pid, "esc")
    assert user_state(pid).focus == :command
  end

  test "the observer is empty and safe before anything is dispatched" do
    {sid, _fake, _} = start_session!()
    {pid, session} = start_tui(sid)

    type(pid, "observer")
    press(pid, "enter")

    text = screen_text(pid, session)
    assert text =~ "nothing running yet"
    assert text =~ "No agents yet."

    # moving the cursor on an empty tree does not crash or move
    press(pid, "down")
    press(pid, "up")
    press(pid, "enter")
    assert user_state(pid).focus == :observer
  end

  test "rows carry state, elapsed time and per-agent tokens" do
    scripts = %{
      "code-1" => [
        {:tool, "delegate", %{"agent" => "explore", "prompt" => "look"}},
        {:finish, "done"}
      ],
      "code-1/explore-1" => [{:finish, "looked"}]
    }

    {sid, _fake, _} = start_session!(scripts: scripts, auto_approve: true)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "go")
    await_state("code-1", :done_unread, 15_000)

    model = Model.rebuild(sid, ".", Troupe.events(sid))
    rows = Model.observer_rows(model)

    assert [root, child] = rows
    assert root.path == "code-1"
    assert root.depth == 0
    assert root.root?
    assert root.agent.name == "code"

    assert child.path == "code-1/explore-1"
    assert child.depth == 1
    refute child.root?
    assert child.agent.name == "explore"

    assert Model.agent_state(root) == :done_unread
    assert Model.agent_state(child) == :done
    assert Model.agent_elapsed(child, System.system_time(:millisecond)) =~ ~r/^\d\d:\d\d$/

    # the Fake reports usage, so each agent carries its own tokens and they sum to the window's
    assert Model.total_tokens(child.agent) > 0

    assert Model.total_tokens(root.agent) + Model.total_tokens(child.agent) ==
             Model.total_tokens(root.window)

    # sent and received are counted apart, and the Fake caches nothing
    assert child.agent.usage.input > 0
    assert child.agent.usage.output > 0
    assert child.agent.usage.cache_read == 0
    assert Model.tokens(child.agent) =~ ~r/^↑[\d.]+k? ↓\d+$/
  end
end
