defmodule Troupe.IsolationTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Session.Locks

  # Done item 24
  test "shared locks: contention returns an error naming the holder and both branches finish" do
    ws = tmp_workspace(%{"shared.txt" => "v1\n"})
    abs = Path.join(ws, "shared.txt")

    scripts = %{
      "code-1" => [
        {:delay, 1_500,
         {:tool, "edit_file", %{"path" => "shared.txt", "old_string" => "v1", "new_string" => "v2"}}},
        {:finish, "one"}
      ],
      "code-2" => [
        {:tool, "edit_file", %{"path" => "shared.txt", "old_string" => "v1", "new_string" => "v3"}},
        {:finish, "two"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    # hold the lock as code-1 so both branches hit the path "at once"
    :ok = Locks.acquire(sid, Troupe.Workspace.canonicalize(abs), "code-1")
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "edit slowly")
    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "edit now")

    await_state("code-2", :done_unread)
    :ok = Locks.release(sid, Troupe.Workspace.canonicalize(abs), "code-1")
    await_state("code-1", :done_unread)

    [failed] = events_of(sid, "code-2", :tool_call_completed) |> Enum.filter(&(&1.data.ok == false))
    assert failed.data.content =~ "locked by branch code-1"
    [ok | _] = events_of(sid, "code-1", :tool_call_completed)
    assert ok.data.ok == true
    assert File.read!(abs) == "v2\n"
  end

  # Done item 25
  test "worktree: isolated write, merge creates a merge commit, discard removes worktree and branch" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      "worktree-1" => [
        {:tool, "write_file", %{"path" => "feature.txt", "content" => "rate limiting\n"}},
        {:finish, "added feature"}
      ],
      "worktree-2" => [
        {:tool, "write_file", %{"path" => "junk.txt", "content" => "x"}},
        {:finish, "junk"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {:ok, p1} = Troupe.dispatch(sid, "worktree", "add rate limiting")
    await_state(p1, :done_unread)

    refute File.exists?(Path.join(ws, "feature.txt"))
    assert run_git!(ws, ["status", "--porcelain"]) == ""
    w = window(sid, p1)
    assert w.worktree.git_branch == "troupe/worktree-1"
    assert w.diff_stat =~ "feature.txt"
    assert File.exists?(Path.join([ws, ".troupe", "worktrees", "worktree-1", "feature.txt"]))

    assert {:ok, _} = Troupe.merge(sid, p1)
    assert File.read!(Path.join(ws, "feature.txt")) == "rate limiting\n"
    assert run_git!(ws, ["log", "--merges", "--oneline"]) =~ "Merge troupe/worktree-1"

    {:ok, p2} = Troupe.dispatch(sid, "worktree", "junk")
    await_state(p2, :done_unread)
    assert {:ok, _} = Troupe.discard(sid, p2)
    refute File.exists?(Path.join([ws, ".troupe", "worktrees", "worktree-2"]))
    refute run_git!(ws, ["branch", "--list", "troupe/worktree-2"]) =~ "worktree-2"
    assert File.read!(Path.join([ws, ".git", "info", "exclude"])) =~ ".troupe/worktrees/"
  end
end
