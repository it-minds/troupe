defmodule Troupe.Tools.ListFiles do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Tool.{Bound, Context}
  alias Troupe.Workspace

  @impl true
  def name, do: "list_files"

  @impl true
  def description,
    do:
      "List files matching a glob pattern (default `**/*`) relative to the workspace root. `.git` and `.troupe/worktrees` are excluded. The number of paths returned is capped; use `offset` (1-based) and `limit` to page through the rest."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Glob such as lib/**/*.ex"},
        "path" => %{
          "type" => "string",
          "description" => "Directory to list from, relative to the workspace"
        },
        "offset" => %{"type" => "integer", "description" => "First path to return (1-based)"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of paths"}
      }
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(args, ctx) do
    pattern = Map.get(args, "pattern") || "**/*"
    base = Map.get(args, "path") || "."

    case Workspace.resolve_readable(ctx.workspace, base, Context.read_roots(ctx)) do
      {:ok, dir} ->
        files =
          Path.join(dir, pattern)
          |> Path.wildcard(match_dot: true)
          |> Enum.reject(&excluded?(&1, ctx.workspace))
          |> Enum.map(&Path.relative_to(&1, relative_root(dir, ctx)))
          |> Enum.sort()

        limits = Context.limits(ctx)
        offset = max(Map.get(args, "offset") || 1, 1)
        limit = max(Map.get(args, "limit") || limits.list_items, 1)

        {:ok,
         files
         |> Bound.items(offset, limit)
         |> Bound.render(fn o ->
           ~s|Call list_files(pattern: #{inspect(pattern)}, offset: #{o.first}, limit: #{limit}) for more, or narrow the pattern.|
         end)}

      {:error, _} ->
        {:error, "path escapes the workspace and the readable roots: #{base}"}
    end
  end

  # Paths print relative to the workspace when they are in it, and relative to
  # the read root otherwise — `Path.relative_to/2` against the wrong root leaves
  # an absolute path, which reads as noise and is not a path the model can reuse.
  defp relative_root(dir, ctx) do
    if String.starts_with?(dir, ctx.workspace), do: ctx.workspace, else: dir
  end

  defp excluded?(path, root) do
    rel = Path.relative_to(path, root)

    String.starts_with?(rel, ".git/") or rel == ".git" or
      String.starts_with?(rel, ".troupe/worktrees")
  end
end
