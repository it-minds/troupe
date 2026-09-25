defmodule Troupe.Gateway.BranchesTest do
  @moduledoc """
  A branch is a session of its own (Decision 646), and its worktree ends in a merge or
  a discard (Decision 647) — through the protocol, against a real repository, because
  what is being checked is what git and the listing actually do.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-br-#{System.unique_integer([:positive])}")
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

  test "the daemon says it does branches", context do
    client = connect(context)
    assert Client.info(client).capabilities["branches"] == true
  end

  test "a session created with a parent is listed under it, in its own worktree", context do
    client = connect(context)

    {:ok, parent} = create(client, context.workspace)
    {:ok, branch} = create(client, context.workspace, %{"parent" => parent["session_id"]})

    assert branch["parent"] == parent["session_id"]
    assert is_binary(branch["worktree"]), "a branch of a live session works in its own tree"

    assert {:ok, %{"sessions" => [row]}} =
             Client.call(client, "session.list", %{
               "filter" => %{"parent" => parent["session_id"]}
             })

    assert row["id"] == branch["session_id"]
    assert row["parent"] == parent["session_id"]

    assert {:ok, %{"parent" => nil}} =
             Client.call(client, "session.get", %{"session_id" => parent["session_id"]})

    # The link is what the log says, so it outlives the actor tree.
    Troupe.stop_session(branch["session_id"])

    assert {:ok, %{"sessions" => [dormant]}} =
             Client.call(client, "session.list", %{
               "filter" => %{"parent" => parent["session_id"]}
             })

    assert dormant["state"] == "dormant"
    assert dormant["parent"] == parent["session_id"]
  end

  test "a parent the daemon does not know is refused, naming the field", context do
    client = connect(context)

    assert {:error, %Error{message: "invalid_params", data: data}} =
             create(client, context.workspace, %{"parent" => Troupe.Session.generate_id()})

    assert data["field"] == "parent"
    assert data["reason"] == "no such session"
  end

  test "worktree.merge commits the branch's work, lands it, and cleans up", context do
    client = connect(context)

    {:ok, parent} = create(client, context.workspace)
    {:ok, branch} = create(client, context.workspace, %{"parent" => parent["session_id"]})
    path = branch["worktree"]

    # What an agent leaves behind: an edit nobody committed.
    File.write!(Path.join(path, "feature.txt"), "from the branch\n")

    assert {:ok, result} =
             Client.call(client, "worktree.merge", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "path" => path,
               "message" => "troupe: the feature"
             })

    assert result["merged"] == true
    assert result["committed"] == true
    assert result["branch"] == branch["branch"]

    assert File.read!(Path.join(context.workspace, "feature.txt")) == "from the branch\n"
    refute File.dir?(path)

    {log, 0} = git(context.workspace, ["log", "--oneline", "-3"])
    assert log =~ "Merge #{branch["branch"]}"
    assert log =~ "troupe: the feature"

    {branches, 0} = git(context.workspace, ["branch", "--list", branch["branch"]])
    assert String.trim(branches) == "", "the merged branch should be gone"
  end

  test "a merge git cannot complete is aborted and leaves both trees alone", context do
    client = connect(context)

    {:ok, parent} = create(client, context.workspace)
    {:ok, branch} = create(client, context.workspace, %{"parent" => parent["session_id"]})
    path = branch["worktree"]

    File.write!(Path.join(path, "README.md"), "# the branch's version\n")
    File.write!(Path.join(context.workspace, "README.md"), "# the person's version\n")
    {_, 0} = git(context.workspace, ["commit", "-am", "person edits readme"])

    assert {:error, %Error{message: "conflict", data: data}} =
             Client.call(client, "worktree.merge", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "path" => path
             })

    assert data["reason"] == "merge conflicts"
    assert is_binary(data["output"])

    assert File.read!(Path.join(context.workspace, "README.md")) == "# the person's version\n"
    assert File.dir?(path), "the worktree is left for the person to resolve"
    {status, 0} = git(context.workspace, ["status", "--porcelain"])
    assert String.trim(status) == "", "the checkout is clean again after the abort"
  end

  test "worktree.discard removes the tree and its branch, work and all", context do
    client = connect(context)

    {:ok, parent} = create(client, context.workspace)
    {:ok, branch} = create(client, context.workspace, %{"parent" => parent["session_id"]})
    path = branch["worktree"]
    File.write!(Path.join(path, "scratch.txt"), "never merged\n")

    assert {:ok, %{"discarded" => true, "branch" => name}} =
             Client.call(client, "worktree.discard", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "path" => path
             })

    assert name == branch["branch"]
    refute File.dir?(path)
    refute File.exists?(Path.join(context.workspace, "scratch.txt"))
    {branches, 0} = git(context.workspace, ["branch", "--list", name])
    assert String.trim(branches) == ""
  end

  test "a path that is not a worktree is refused", context do
    client = connect(context)
    stray = Path.join(context.base, "stray")
    File.mkdir_p!(stray)

    assert {:error, %Error{message: "invalid_params"}} =
             Client.call(client, "worktree.discard", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "path" => stray
             })

    assert {:error, %Error{message: "not_found"}} =
             Client.call(client, "worktree.merge", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "path" => Path.join(context.base, "nowhere")
             })
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context) do
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp create(client, workspace, extra \\ %{}) do
    params =
      Map.merge(
        %{
          "command_id" => Client.command_id(),
          "workspace" => workspace,
          "worktree" => "auto",
          "config" => %{"auto_approve" => true}
        },
        extra
      )

    result = Client.call(client, "session.create", params)

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
