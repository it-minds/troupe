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

defmodule Troupe.ExistingWorktreeTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Session.Worktree

  test "/worktree <checked-out worktree> <prompt> works in the user's worktree and never commits there" do
    ws = tmp_workspace() |> git_init!()
    run_git!(ws, ["worktree", "add", "feature/design", "-b", "design"])

    assert [%{rel: "feature/design", branch: "design"}] = Worktree.list(ws)
    assert Worktree.find(ws, "design").rel == "feature/design"
    assert Worktree.find(ws, "feature/design/").branch == "design"
    assert Worktree.find(ws, "nope") == nil

    scripts = %{
      "worktree-1" => [
        {:tool, "write_file", %{"path" => "design.md", "content" => "# design\n"}},
        {:finish, "wrote the design"}
      ]
    }

    {sid, fake, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {:ok, "worktree-1"} = Troupe.dispatch(sid, "worktree", "feature/design write the design doc")
    await_state("worktree-1", :done_unread, 15_000)

    # the prompt lost the worktree token, the file landed in the user's worktree, uncommitted
    [req | _] = Troupe.LLM.Fake.requests(fake)
    assert Troupe.LLM.Message.text(hd(req.messages).content) == "write the design doc"
    assert req.system =~ "Workspace root: #{Path.join(ws, "feature/design")}"
    assert File.exists?(Path.join([ws, "feature/design", "design.md"]))
    refute File.exists?(Path.join(ws, "design.md"))
    assert run_git!(Path.join(ws, "feature/design"), ["status", "--porcelain"]) =~ "design.md"

    assert run_git!(Path.join(ws, "feature/design"), ["log", "--oneline"])
           |> String.split("\n", trim: true)
           |> length() == 1

    refute File.exists?(Path.join([ws, ".troupe", "worktrees", "worktree-1"]))

    w = window(sid, "worktree-1")
    assert w.worktree.managed == false
    assert w.diff_stat =~ "design.md"
    assert {:error, msg} = Troupe.merge(sid, "worktree-1")
    assert msg =~ "your own worktree"

    # an unknown first word is just part of the prompt and gets a Troupe-managed worktree
    Troupe.LLM.Fake.script_for(fake, "worktree-2", [{:finish, "ok"}])
    {:ok, "worktree-2"} = Troupe.dispatch(sid, "worktree", "sketch something else")
    await_state("worktree-2", :done_unread, 15_000)
    assert window(sid, "worktree-2").worktree.git_branch == "troupe/worktree-2"

    assert Troupe.LLM.Message.text(
             hd(
               Enum.find(Troupe.LLM.Fake.requests(fake), &(&1.agent_path == "worktree-2")).messages
             ).content
           ) == "sketch something else"
  end

  # Decision 42
  test "/worktree <name>: <prompt> creates the named worktree, then reuses it" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      "worktree-1" => [
        {:tool, "write_file", %{"path" => "auth.ex", "content" => "one\n"}},
        {:finish, "first pass"}
      ],
      "worktree-2" => [
        {:tool, "write_file", %{"path" => "auth_test.exs", "content" => "two\n"}},
        {:finish, "second pass"}
      ]
    }

    {sid, fake, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)

    {:ok, "worktree-1"} = Troupe.dispatch(sid, "worktree", "feat-auth: add rate limiting")
    await_state("worktree-1", :done_unread, 15_000)

    wt = Path.join([ws, ".troupe", "worktrees", "feat-auth"])
    assert File.exists?(Path.join(wt, "auth.ex"))
    assert window(sid, "worktree-1").worktree.git_branch == "troupe/feat-auth"
    assert window(sid, "worktree-1").worktree.managed
    assert Worktree.managed(ws) == ["feat-auth"]

    # the name is not part of the prompt
    [req | _] = Troupe.LLM.Fake.requests(fake)
    assert Troupe.LLM.Message.text(hd(req.messages).content) == "add rate limiting"
    assert req.system =~ "Workspace root: #{wt}"

    # a second branch with the same name reuses the worktree and sees the first branch's work
    {:ok, "worktree-2"} = Troupe.dispatch(sid, "worktree", "feat-auth: now add tests")
    await_state("worktree-2", :done_unread, 15_000)
    assert window(sid, "worktree-2").worktree.git_branch == "troupe/feat-auth"
    assert File.read!(Path.join(wt, "auth.ex")) == "one\n"
    assert File.exists?(Path.join(wt, "auth_test.exs"))

    # Troupe commits there and /merge brings the whole branch into the checkout
    assert {:ok, _} = Troupe.merge(sid, "worktree-2")
    assert File.read!(Path.join(ws, "auth.ex")) == "one\n"
    assert File.read!(Path.join(ws, "auth_test.exs")) == "two\n"
    assert run_git!(ws, ["log", "--merges", "--oneline"]) =~ "Merge troupe/feat-auth"
  end

  test "a named worktree in use by a running branch is refused, and a bad name is reported" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      "worktree-1" => [{:delay, 60_000, {:finish, "never"}}],
      "worktree-2" => [{:finish, "ok"}]
    }

    {sid, _fake, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)

    {:ok, "worktree-1"} = Troupe.dispatch(sid, "worktree", "feat-auth: long task")
    assert window(sid, "worktree-1").state == :running

    assert {:error, msg} = Troupe.dispatch(sid, "worktree", "feat-auth: something else")
    assert msg == "worktree feat-auth is already in use by worktree-1"

    assert {:error, msg} = Troupe.dispatch(sid, "worktree", "../escape: nope")
    assert msg =~ "not a usable worktree name"

    assert {:error, msg} = Troupe.dispatch(sid, "worktree", "feat-auth:")
    assert msg =~ "give a prompt after the worktree name"

    # the refusals cost no branch: the next dispatch is still worktree-2
    assert {:ok, "worktree-2"} = Troupe.dispatch(sid, "worktree", "unrelated work")
  end

  test "a named worktree whose directory was removed is recreated on its surviving branch" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      "worktree-1" => [
        {:tool, "write_file", %{"path" => "kept.txt", "content" => "kept\n"}},
        {:finish, "one"}
      ],
      "worktree-2" => [{:finish, "two"}]
    }

    {sid, _fake, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {:ok, "worktree-1"} = Troupe.dispatch(sid, "worktree", "feat-auth: write a file")
    await_state("worktree-1", :done_unread, 15_000)

    wt = Path.join([ws, ".troupe", "worktrees", "feat-auth"])
    run_git!(ws, ["worktree", "remove", "--force", wt])
    refute File.exists?(wt)
    assert run_git!(ws, ["branch", "--list", "troupe/feat-auth"]) =~ "feat-auth"

    {:ok, "worktree-2"} = Troupe.dispatch(sid, "worktree", "feat-auth: carry on")
    await_state("worktree-2", :done_unread, 15_000)
    assert File.read!(Path.join(wt, "kept.txt")) == "kept\n"
  end
end
