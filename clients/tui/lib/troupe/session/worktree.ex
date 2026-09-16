defmodule Troupe.Session.Worktree do
  @moduledoc "git worktree operations for `worktree` isolation. All git calls run under reaper."

  alias Troupe.OS

  @spec path(String.t(), String.t()) :: String.t()
  def path(workspace, branch_id), do: Path.join([workspace, ".troupe", "worktrees", branch_id])

  @spec git_branch(String.t()) :: String.t()
  def git_branch(branch_id), do: "troupe/" <> branch_id

  @spec create(String.t(), String.t()) ::
          {:ok, %{path: String.t(), git_branch: String.t()}} | {:error, String.t()}
  def create(workspace, branch_id) do
    wt = path(workspace, branch_id)
    branch = git_branch(branch_id)
    File.mkdir_p!(Path.dirname(wt))

    cond do
      registered?(workspace, wt) ->
        add_exclude(workspace)
        {:ok, %{path: wt, git_branch: branch}}

      File.exists?(wt) ->
        {:error, "#{wt} exists but is not a git worktree; remove it or use another name"}

      # A named worktree that was discarded as a directory but whose branch survived.
      branch_exists?(workspace, branch) ->
        add(workspace, wt, branch, [wt, branch])

      true ->
        add(workspace, wt, branch, [wt, "-b", branch])
    end
  end

  defp add(workspace, wt, branch, args) do
    case git(workspace, ["worktree", "add" | args]) do
      {:ok, _, 0} ->
        add_exclude(workspace)
        {:ok, %{path: wt, git_branch: branch}}

      {:ok, out, _} ->
        {:error, "git worktree add failed: #{out}"}

      {:error, :timeout, out} ->
        {:error, "git worktree add timed out: #{out}"}
    end
  end

  @doc "True when `git worktree list` already knows this directory."
  @spec registered?(String.t(), String.t()) :: boolean()
  def registered?(workspace, wt) do
    canonical = canonical(wt)
    Enum.any?(all(workspace), &(&1.path == canonical))
  end

  defp branch_exists?(workspace, branch) do
    match?(
      {:ok, _, 0},
      git(workspace, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
    )
  end

  @doc "Names of the worktrees Troupe manages under `.troupe/worktrees`."
  @spec managed(String.t()) :: [String.t()]
  def managed(workspace) do
    workspace
    |> Path.join(".troupe/worktrees/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  @doc "Commits everything in the worktree on its branch; returns a diff stat (or empty string if nothing changed)."
  @spec commit(String.t(), String.t()) :: String.t()
  def commit(wt, message) do
    with {:ok, _, 0} <- git(wt, ["add", "-A"]),
         {:ok, status, 0} <- git(wt, ["status", "--porcelain"]),
         true <- String.trim(status) != "",
         {:ok, _, 0} <-
           git(wt, [
             "-c",
             "user.name=troupe",
             "-c",
             "user.email=troupe@localhost",
             "commit",
             "-q",
             "-m",
             message
           ]),
         {:ok, stat, 0} <- git(wt, ["show", "--stat", "--format=", "HEAD"]) do
      String.trim(stat)
    else
      _ -> ""
    end
  end

  @spec merge(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def merge(workspace, branch_id) do
    branch = git_branch(branch_id)

    case git(workspace, ["merge", "--no-ff", "--no-edit", "-m", "Merge #{branch}", branch]) do
      {:ok, out, 0} -> {:ok, out}
      {:ok, out, _} -> {:error, "merge conflicts or failure; resolve in your checkout:\n#{out}"}
      {:error, :timeout, out} -> {:error, "git merge timed out: #{out}"}
    end
  end

  @spec discard(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def discard(workspace, branch_id) do
    wt = path(workspace, branch_id)
    {:ok, out1, _} = ok(git(workspace, ["worktree", "remove", "--force", wt]))
    {:ok, out2, s2} = ok(git(workspace, ["branch", "-D", git_branch(branch_id)]))
    File.rm_rf(wt)
    if s2 == 0, do: {:ok, out1 <> out2}, else: {:error, out1 <> out2}
  end

  @doc """
  Worktrees the user has checked out (from `git worktree list`), excluding the
  workspace itself and Troupe's own `.troupe/worktrees`. Each has `path`,
  `rel` (relative to the workspace when inside it) and `branch`.
  """
  @spec list(String.t()) :: [%{path: String.t(), rel: String.t(), branch: String.t() | nil}]
  def list(workspace) do
    root = Path.expand(workspace)
    # git reports canonical paths; the workspace root may reach them through a
    # symlink (macOS /var -> /private/var), so compare canonicalized and report
    # paths back under the root as the user gave it.
    real_root = canonical(workspace)

    workspace
    |> all()
    |> Enum.reject(
      &(&1.path in [nil, real_root] or String.contains?(&1.path, "/.troupe/worktrees/"))
    )
    |> Enum.map(fn wt ->
      if String.starts_with?(wt.path, real_root <> "/") do
        rel = Path.relative_to(wt.path, real_root)
        %{wt | rel: rel, path: Path.join(root, rel)}
      else
        %{wt | rel: wt.path}
      end
    end)
  end

  # Every worktree git knows about, Troupe's own included.
  defp all(workspace) do
    case git(workspace, ["worktree", "list", "--porcelain"]) do
      {:ok, out, 0} ->
        out
        |> String.split(~r/\n\s*\n/, trim: true)
        |> Enum.map(&parse_worktree/1)

      _ ->
        []
    end
  end

  defp parse_worktree(block) do
    lines = String.split(block, "\n", trim: true)

    path =
      lines
      |> Enum.find_value(fn
        "worktree " <> p -> p
        _ -> nil
      end)

    branch =
      lines
      |> Enum.find_value(fn
        "branch refs/heads/" <> b -> b
        _ -> nil
      end)

    %{path: path && Path.expand(path), rel: path, branch: branch}
  end

  @doc "Finds a user worktree by relative path, absolute path or branch name."
  @spec find(String.t(), String.t()) ::
          %{path: String.t(), rel: String.t(), branch: String.t() | nil} | nil
  def find(workspace, name) do
    name = String.trim_trailing(name, "/")

    Enum.find(list(workspace), fn wt ->
      name in [wt.rel, wt.path, wt.branch] or
        (Path.type(name) == :absolute and canonical(name) == canonical(wt.path))
    end)
  end

  # git reports worktree paths with symlinks resolved, so any path Troupe
  # compares against one has to be resolved the same way.
  defp canonical(path), do: path |> Path.expand() |> Troupe.Workspace.canonicalize()

  @doc "Uncommitted change summary of a user-managed worktree (nothing is committed)."
  @spec diff_stat(String.t()) :: String.t()
  def diff_stat(wt) do
    with {:ok, _, 0} <- git(wt, ["add", "-N", "-A"]),
         {:ok, stat, 0} <- git(wt, ["diff", "--stat"]) do
      String.trim(stat)
    else
      _ -> ""
    end
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(workspace, branch_id), do: File.dir?(path(workspace, branch_id))

  defp ok({:error, :timeout, out}), do: {:ok, out, 1}
  defp ok(other), do: other

  defp add_exclude(workspace) do
    case git(workspace, ["rev-parse", "--git-common-dir"]) do
      {:ok, dir, 0} ->
        exclude = Path.join([Path.expand(String.trim(dir), workspace), "info", "exclude"])
        File.mkdir_p!(Path.dirname(exclude))

        existing =
          File.read(exclude)
          |> case do
            {:ok, c} -> c
            _ -> ""
          end

        unless String.contains?(existing, ".troupe/worktrees/") do
          File.write!(exclude, existing <> "\n.troupe/worktrees/\n")
        end

      _ ->
        :ok
    end
  end

  defp git(cwd, args), do: OS.Process.run("git", args, cd: cwd, timeout_ms: 60_000)
end
