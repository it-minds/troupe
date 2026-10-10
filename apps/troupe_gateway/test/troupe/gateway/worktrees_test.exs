defmodule Troupe.Gateway.WorktreesTest do
  @moduledoc """
  Two sessions in one repository, through the protocol.

  Without a worktree the second agent edits the same checkout as the first, and each
  sees the other's half-finished work as if the user had made it — which is worse than
  either of them failing. These drive real `git` against a real repository, because
  the thing being checked is what git does, not what we think it does.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Worktrees}
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

  # The desktop app removes a worktree with `worktree.remove`, and on Windows git cannot
  # delete the directory it was started in (Decision 843): the git that removes the tree is
  # started in the checkout it belongs to. A stand-in for git on PATH says where it was
  # started, which nothing here would otherwise show.
  test "worktree.remove runs git from the checkout, not inside the tree it removes", context do
    client = connect(context)

    {:ok, _first} = create(client, context.workspace)
    {:ok, second} = create(client, context.workspace)
    started_in = record_removals(context.base)

    assert {:ok, %{"removed" => true}} =
             Client.call(client, "worktree.remove", %{
               "command_id" => Client.command_id(),
               "path" => second["worktree"]
             })

    refute File.dir?(second["worktree"])
    assert [cwd] = started_in.()
    assert cwd == real!(context.workspace)
  end

  # TUI Decision 42, in the daemon: `/worktree login: …` works in `<checkout>-login` on
  # `troupe/login`, the same tree every time, made again from its branch when only the
  # directory went.
  test "a named worktree is made on troupe/<name> the first time and is the same one after",
       context do
    client = connect(context)

    {:ok, _first} = create(client, context.workspace)
    assert {:ok, named} = create(client, context.workspace, "always", "login")
    assert named["branch"] == "troupe/login"
    assert Path.basename(named["worktree"]) == "repo-login"
    assert named["workspace"] == named["worktree"]
    File.write!(Path.join(named["worktree"], "kept.txt"), "still here\n")
    Troupe.stop_session(named["session_id"])

    assert {:ok, again} = create(client, context.workspace, "always", "login")
    assert again["worktree"] == named["worktree"]
    assert File.read!(Path.join(again["worktree"], "kept.txt")) == "still here\n"
    Troupe.stop_session(again["session_id"])

    File.rm_rf!(named["worktree"])
    assert {:ok, back} = create(client, context.workspace, "always", "login")
    assert back["worktree"] == named["worktree"]
    assert back["branch"] == "troupe/login"
    assert File.dir?(back["worktree"])

    for bad <- ["../up", "two words", "-x", "a..b", ".hidden", "x.lock", ""] do
      assert {:error, %Error{message: "invalid_params", data: %{"field" => "worktree_name"}}} =
               create(client, context.workspace, "always", bad),
             bad
    end
  end

  test "worktree: never keeps the second session in the repository itself", context do
    client = connect(context)

    {:ok, _first} = create(client, context.workspace)
    {:ok, second} = create(client, context.workspace, "never")

    assert second["worktree"] == nil
    assert second["workspace"] == context.workspace
  end

  # #529 (Decision 833): the gateway's own git runs none of the commands the repository's
  # `.git` names, as it makes a worktree, commits what was left in it and merges it.
  describe "a repository whose own .git runs commands" do
    setup %{base: base, workspace: workspace} do
      marker = Path.join(base, "marker")
      script = Path.join(base, "mark.sh")
      File.write!(script, "#!/bin/sh\necho \"$*\" >> '#{marker}'\ncat\n")
      File.chmod!(script, 0o755)

      File.write!(Path.join(workspace, ".gitattributes"), "*.txt merge=mark filter=mark\n")
      File.write!(Path.join(workspace, "notes.txt"), "one\n")
      quiet!(workspace, ["add", "."])
      quiet!(workspace, ["commit", "-q", "-m", "notes"])

      {_, 0} = git(workspace, ["config", "core.fsmonitor", "#{script} fsmonitor"])
      {_, 0} = git(workspace, ["config", "merge.mark.driver", "#{script} merge %O %A %B"])
      {_, 0} = git(workspace, ["config", "filter.mark.smudge", "#{script} smudge"])
      {_, 0} = git(workspace, ["config", "filter.mark.clean", "#{script} clean"])
      hooks = Path.join(workspace, ".git/hooks")
      File.mkdir_p!(hooks)

      named = ~w(post-checkout pre-commit commit-msg post-commit pre-merge-commit post-merge)

      for hook <- named ++ ~w(reference-transaction post-index-change) do
        File.write!(Path.join(hooks, hook), "#!/bin/sh\n#{script} hook #{hook} </dev/null\n")
        File.chmod!(Path.join(hooks, hook), 0o755)
      end

      %{marker: marker}
    end

    test "a worktree is made, its work committed and merged without running any", context do
      %{workspace: workspace, marker: marker} = context

      assert {:ok, %{path: wt, branch: branch}} = Worktrees.create(workspace)
      on_exit(fn -> File.rm_rf!(wt) end)
      assert File.read!(Path.join(wt, "notes.txt")) == "one\n"
      File.write!(Path.join(wt, "feature.md"), "new\n")

      assert [%{"dirty" => false}, %{"dirty" => true}] =
               Worktrees.list(workspace) |> Enum.sort_by(& &1["path"])

      assert {:ok, %{"branch" => ^branch, "committed" => true}} = Worktrees.merge(workspace, wt)

      assert File.read!(Path.join(workspace, "feature.md")) == "new\n"
      refute File.exists?(marker), "ran: #{ran(marker)}"
    end

    test "a file only the repository's merge driver would merge is a conflict", context do
      %{workspace: workspace, marker: marker} = context

      assert {:ok, %{path: wt}} = Worktrees.create(workspace)
      on_exit(fn -> File.rm_rf!(wt) end)
      File.write!(Path.join(wt, "notes.txt"), "one\ntwo\n")
      File.write!(Path.join(workspace, "notes.txt"), "zero\none\n")
      quiet!(workspace, ["commit", "-q", "-am", "zero"])

      assert {:error, {:conflicts, output}} = Worktrees.merge(workspace, wt)
      assert output =~ "notes.txt"
      assert File.read!(Path.join(workspace, "notes.txt")) == "zero\none\n"
      refute File.exists?(marker), "ran: #{ran(marker)}"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp ran(marker) do
    case File.read(marker) do
      {:ok, ran} -> ran
      {:error, _} -> ""
    end
  end

  # The test's own git, which would run what the repository names.
  defp quiet!(cwd, args) do
    off = ~w(core.fsmonitor=false core.hooksPath=/dev/null filter.mark.clean= filter.mark.smudge=)
    {_, 0} = git(cwd, Enum.flat_map(off, &["-c", &1]) ++ args)
  end

  defp connect(context) do
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  # A `git` first on PATH that writes where it was started for every `worktree remove`,
  # then runs the real one; the function reads those back. PATH is the VM's own, and this
  # module is not async.
  defp record_removals(base) do
    real_git = System.find_executable("git")
    bin = Path.join(base, "bin")
    log = Path.join(base, "removals.log")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    case "$*" in *"worktree remove"*) pwd -P >> '#{log}' ;; esac
    exec '#{real_git}' "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    fn ->
      case File.read(log) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        {:error, _} -> []
      end
    end
  end

  defp real!(path) do
    {:ok, real} = Troupe.Workspace.real_path(path)
    real
  end

  defp create(client, workspace, worktree \\ "auto", name \\ nil) do
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
