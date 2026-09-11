defmodule Troupe.Gateway.WorktreesTest do
  @moduledoc """
  Two sessions in one repository, through the protocol.

  Without a worktree the second agent edits the same checkout as the first, and each
  sees the other's half-finished work as if the user had made it — which is worse than
  either of them failing. These drive real `git` against a real repository, because
  the thing being checked is what git does, not what we think it does.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-wt-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "repo")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    init_repo(workspace)

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

    %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint}
  end

  test "a second session in a live workspace gets its own worktree on troupe/<slug>", context do
    client = connect(context)

    assert {:ok, first} = create(client, context.workspace)
    assert first["worktree"] == nil, "the first session should work in the repository itself"
    assert first["workspace"] == context.workspace

    assert {:ok, second} = create(client, context.workspace)
    assert is_binary(second["worktree"]), "the second session should have got its own worktree"
    assert second["branch"] =~ ~r"^troupe/[a-z0-9]+$"
    assert second["workspace"] == second["worktree"]
    assert File.dir?(second["worktree"])

    # Git agrees, which is the part that matters when someone opens the directory.
    assert {output, 0} = git(second["worktree"], ["rev-parse", "--abbrev-ref", "HEAD"])
    assert String.trim(output) == second["branch"]

    assert {:ok, %{"worktrees" => worktrees}} =
             Client.call(client, "worktree.list", %{"workspace" => context.workspace})

    paths = Enum.map(worktrees, & &1["path"])
    assert second["worktree"] in paths
  end

  test "worktree.remove refuses a dirty tree without force, and obeys it with force", context do
    client = connect(context)

    {:ok, _first} = create(client, context.workspace)
    {:ok, second} = create(client, context.workspace)
    path = second["worktree"]

    # Uncommitted work in a worktree is usually the only copy of it.
    File.write!(Path.join(path, "scratch.txt"), "work nobody committed\n")

    assert {:error, %Error{message: "conflict", data: data}} =
             Client.call(client, "worktree.remove", %{
               "command_id" => Client.command_id(),
               "path" => path
             })

    assert data["reason"] =~ "local changes"
    assert File.dir?(path), "the worktree was removed despite being dirty"

    assert {:ok, %{"removed" => true}} =
             Client.call(client, "worktree.remove", %{
               "command_id" => Client.command_id(),
               "path" => path,
               "force" => true
             })

    refute File.dir?(path)
  end

  test "a clean worktree is removed without force", context do
    client = connect(context)

    {:ok, _first} = create(client, context.workspace)
    {:ok, second} = create(client, context.workspace)

    assert {:ok, %{"removed" => true}} =
             Client.call(client, "worktree.remove", %{
               "command_id" => Client.command_id(),
               "path" => second["worktree"]
             })

    refute File.dir?(second["worktree"])
  end

  test "worktree: never keeps the second session in the repository itself", context do
    client = connect(context)

    {:ok, _first} = create(client, context.workspace)
    {:ok, second} = create(client, context.workspace, "never")

    assert second["worktree"] == nil
    assert second["workspace"] == context.workspace
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context) do
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp create(client, workspace, worktree \\ "auto") do
    result =
      Client.call(client, "session.create", %{
        "command_id" => Client.command_id(),
        "workspace" => workspace,
        "worktree" => worktree,
        "config" => %{"auto_approve" => true}
      })

    with {:ok, %{"session_id" => id}} <- result do
      on_exit(fn -> Troupe.stop_session(id) end)
    end

    result
  end

  defp init_repo(path) do
    {_, 0} = git(path, ["init", "--initial-branch", "main"])
    {_, 0} = git(path, ["config", "user.email", "test@example.com"])
    {_, 0} = git(path, ["config", "user.name", "Troupe Test"])
    File.write!(Path.join(path, "README.md"), "# repo\n")
    {_, 0} = git(path, ["add", "."])
    {_, 0} = git(path, ["commit", "-m", "first"])
    :ok
  end

  defp git(cwd, args), do: System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
end
