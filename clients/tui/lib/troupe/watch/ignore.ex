defmodule Troupe.Watch.Ignore do
  @moduledoc """
  Ignore rules shared by both backends: `.git/`, `.troupe/worktrees/` and
  anything `.gitignore`d (via `git`, when the workspace is a repository).
  """

  alias Troupe.OS

  @spec always_ignored?(String.t(), String.t()) :: boolean()
  def always_ignored?(workspace, abs_path) do
    rel = Path.relative_to(abs_path, workspace)

    rel == ".git" or String.starts_with?(rel, ".git/") or
      String.starts_with?(rel, ".troupe/worktrees") or
      String.contains?(rel, "/.git/")
  end

  @doc "Drops always-ignored and gitignored paths."
  @spec filter(String.t(), [String.t()]) :: [String.t()]
  def filter(workspace, paths) do
    paths = Enum.reject(paths, &always_ignored?(workspace, &1))

    if paths != [] and git_repo?(workspace) do
      rels = Enum.map(paths, &Path.relative_to(&1, workspace))

      ignored =
        case OS.Process.run("git", ["check-ignore", "--" | rels], cd: workspace, timeout_ms: 10_000) do
          {:ok, out, 0} -> out |> String.split("\n", trim: true) |> MapSet.new()
          _ -> MapSet.new()
        end

      paths
      |> Enum.zip(rels)
      |> Enum.reject(fn {_abs, rel} -> MapSet.member?(ignored, rel) end)
      |> Enum.map(&elem(&1, 0))
    else
      paths
    end
  end

  @doc "All non-ignored regular files in the workspace (absolute paths)."
  @spec candidate_files(String.t()) :: [String.t()]
  def candidate_files(workspace) do
    files =
      if git_repo?(workspace) do
        case OS.Process.run("git", ["ls-files", "-co", "--exclude-standard"],
               cd: workspace,
               timeout_ms: 10_000
             ) do
          {:ok, out, 0} ->
            out |> String.split("\n", trim: true) |> Enum.map(&Path.join(workspace, &1))

          _ ->
            walk(workspace)
        end
      else
        walk(workspace)
      end

    files |> Enum.reject(&always_ignored?(workspace, &1)) |> Enum.filter(&File.regular?/1)
  end

  defp walk(workspace) do
    workspace |> Path.join("**/*") |> Path.wildcard(match_dot: true)
  end

  @spec git_repo?(String.t()) :: boolean()
  def git_repo?(workspace), do: File.exists?(Path.join(workspace, ".git"))
end
