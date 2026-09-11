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

    case git(workspace, ["worktree", "add", wt, "-b", branch]) do
      {:ok, _, 0} ->
        add_exclude(workspace)
        {:ok, %{path: wt, git_branch: branch}}

      {:ok, out, _} ->
        {:error, "git worktree add failed: #{out}"}

      {:error, :timeout, out} ->
        {:error, "git worktree add timed out: #{out}"}
    end
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
