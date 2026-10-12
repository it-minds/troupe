defmodule Troupe.Gateway.EnclosingRepositoryTest do
  @moduledoc """
  A workspace inside another repository follows git (#650). A folder the repository
  tracks, or one it would add, belongs to it: its worktrees are the repository's, made
  beside the checkout, and its brief is the repository's. A folder the repository ignores
  is a workspace of its own, as one outside any repository is: no worktree of the
  repository around it, and a brief of its own that no librarian refreshes by itself.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Worktrees}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-enc-#{System.unique_integer([:positive])}")
    outer = Path.join(base, "outer")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(state_dir)

    # The repository around the workspaces: a folder it ignores, one it tracks, one it
    # would add (untracked, not ignored), and one linked worktree of its own.
    File.mkdir_p!(Path.join(outer, "scratch/ws"))
    File.mkdir_p!(Path.join(outer, "packages/ws"))
    File.mkdir_p!(Path.join(outer, "fresh/ws"))
    {_, 0} = git(outer, ["init", "--initial-branch", "main"])
    {_, 0} = git(outer, ["config", "user.email", "test@example.com"])
    {_, 0} = git(outer, ["config", "user.name", "Troupe Test"])
    File.write!(Path.join(outer, ".gitignore"), "scratch/\n")
    File.write!(Path.join(outer, "packages/ws/README.md"), "# a package\n")
    {_, 0} = git(outer, ["add", ".gitignore", "packages"])
    {_, 0} = git(outer, ["commit", "-q", "-m", "fixture"])
    linked = Path.join(base, "outer-linked")
    {_, 0} = git(outer, ["worktree", "add", "-q", "-b", "linked", linked])

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{base: base, outer: outer, linked: linked, client: client}
  end

  test "a folder the repository ignores is a workspace of its own", context do
    %{outer: outer, client: client} = context
    ws = Path.join(outer, "scratch/ws")
    trees = registered(outer)

    # No worktree of the repository around it, with or without their status.
    assert {:ok, %{"worktrees" => []}} =
             Client.call(client, "worktree.list", %{"workspace" => ws})

    assert {:ok, %{"worktrees" => []}} =
             Client.call(client, "worktree.list", %{"workspace" => ws, "status" => false})

    # Its own brief, which no librarian refreshes by itself: it is no repository's.
    assert {:ok, brief} = Client.call(client, "memory.get", %{"workspace" => ws})
    assert brief["path"] == Path.join(ws, ".troupe/memory.md")
    assert %{"status" => "absent", "refresh_due" => false, "repository" => false} = brief

    # A session there works in the folder itself, whatever the mode, and a second one is
    # not given a worktree of the repository either.
    assert {:ok, first} = create(client, ws, "always")
    assert %{"worktree" => nil, "branch" => nil, "workspace" => ^ws} = first
    refute Worktrees.auto?(ws)
    assert {:ok, %{"worktree" => nil, "workspace" => ^ws}} = create(client, ws, "auto")

    # A named worktree is refused, saying why, rather than made of the repository.
    assert {:error, %Error{message: "invalid_params", data: data}} =
             create(client, ws, "auto", "login")

    assert data["field"] == "workspace"
    assert data["reason"] =~ "ignores"

    assert registered(outer) == trees
    assert File.ls!(Path.join(outer, "scratch")) == ["ws"]
  end

  test "a folder the repository tracks belongs to it", context do
    %{base: base, outer: outer, linked: linked, client: client} = context
    ws = Path.join(outer, "packages/ws")

    # The repository's worktrees, the checkout first.
    assert {:ok, %{"worktrees" => [checkout, tree]}} =
             Client.call(client, "worktree.list", %{"workspace" => ws})

    assert same?(checkout["path"], outer)
    assert same?(tree["path"], linked)
    assert %{"branch" => "main", "checked" => true, "dirty" => false} = checkout

    # The repository's brief, which a librarian may refresh.
    assert {:ok, brief} = Client.call(client, "memory.get", %{"workspace" => ws})
    assert same?(brief["path"], Path.join(outer, ".troupe/memory.md"))
    assert %{"status" => "absent", "refresh_due" => true, "repository" => true} = brief

    # A worktree of the repository is made beside the checkout, not inside it, and the
    # session works in the same folder of it.
    assert {:ok, made} = create(client, ws, "always")
    assert Path.dirname(made["worktree"]) |> same?(base)
    assert Path.basename(made["worktree"]) =~ ~r/^outer-[a-z0-9]+$/
    assert made["workspace"] == Path.join(made["worktree"], "packages/ws")
    assert File.read!(Path.join(made["workspace"], "README.md")) == "# a package\n"

    assert {:ok, named} = create(client, ws, "auto", "login")
    assert named["worktree"] |> same?(Path.join(base, "outer-login"))
    assert named["workspace"] == Path.join(named["worktree"], "packages/ws")
    assert named["branch"] == "troupe/login"

    refute File.exists?(Path.join(outer, "packages/ws-login"))
    assert File.ls!(Path.join(outer, "packages")) == ["ws"]

    # Each new tree's row names the session working in its folder.
    {:ok, %{"worktrees" => rows}} = Client.call(client, "worktree.list", %{"workspace" => ws})
    row = Enum.find(rows, &same?(&1["path"], named["worktree"]))
    assert row["session_id"] == named["session_id"]
  end

  # One git would add with `git add -A` belongs too; a worktree has only what is committed,
  # so the session's folder is made there, empty.
  test "a folder the repository would add belongs to it", context do
    %{base: base, outer: outer, client: client} = context
    ws = Path.join(outer, "fresh/ws")

    assert {:ok, %{"worktrees" => [_, _]}} =
             Client.call(client, "worktree.list", %{"workspace" => ws, "status" => false})

    assert {:ok, %{"repository" => true} = brief} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    assert same?(brief["path"], Path.join(outer, ".troupe/memory.md"))

    assert {:ok, made} = create(client, ws, "always")
    assert Path.dirname(made["worktree"]) |> same?(base)
    assert made["workspace"] == Path.join(made["worktree"], "fresh/ws")
    assert File.dir?(made["workspace"])
  end

  # -- helpers ----------------------------------------------------------------

  defp registered(outer) do
    {out, 0} = git(outer, ["worktree", "list", "--porcelain"])
    out |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "worktree "))
  end

  defp same?(a, b), do: key(a) == key(b)

  defp key(path) do
    {:ok, real} = Troupe.Workspace.real_path(path)
    Troupe.Workspace.compare_key(real)
  end

  defp create(client, workspace, worktree, name \\ nil) do
    params =
      %{
        "command_id" => Client.command_id(),
        "workspace" => workspace,
        "worktree" => worktree,
        "config" => %{"auto_approve" => true}
      }

    params = if name, do: Map.put(params, "worktree_name", name), else: params
    result = Client.call(client, "session.create", params)

    with {:ok, %{"session_id" => id}} <- result do
      on_exit(fn -> Troupe.stop_session(id) end)
    end

    result
  end

  defp git(cwd, args), do: System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
end
