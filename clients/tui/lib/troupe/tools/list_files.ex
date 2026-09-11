defmodule Troupe.Tools.ListFiles do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Workspace

  @max 2000

  @impl true
  def name, do: "list_files"

  @impl true
  def description,
    do:
      "List files matching a glob pattern (default `**/*`) relative to the workspace root. `.git` and `.troupe/worktrees` are excluded. Returns at most #{@max} paths."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Glob such as lib/**/*.ex"},
        "path" => %{
          "type" => "string",
          "description" => "Directory to list from, relative to the workspace"
        }
      }
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(args, ctx) do
    pattern = Map.get(args, "pattern") || "**/*"
    base = Map.get(args, "path") || "."

    case Workspace.resolve(ctx.workspace, base) do
      {:ok, dir} ->
        files =
          Path.join(dir, pattern)
          |> Path.wildcard(match_dot: true)
          |> Enum.reject(&excluded?(&1, ctx.workspace))
          |> Enum.map(&Path.relative_to(&1, ctx.workspace))
          |> Enum.sort()

        shown = Enum.take(files, @max)
        suffix = if length(files) > @max, do: "\n[#{length(files) - @max} more not shown]", else: ""
        {:ok, Enum.join(shown, "\n") <> suffix}

      {:error, _} ->
        {:error, "path escapes the workspace: #{base}"}
    end
  end

  defp excluded?(path, root) do
    rel = Path.relative_to(path, root)

    String.starts_with?(rel, ".git/") or rel == ".git" or
      String.starts_with?(rel, ".troupe/worktrees")
  end
end
