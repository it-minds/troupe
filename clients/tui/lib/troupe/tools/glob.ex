defmodule Troupe.Tools.Glob do
  @moduledoc """
  Find files by name. `list_files` already globs, but it sorts by path and is
  meant for surveying a directory; this answers "where is the file called X",
  which is what `find` was being used for inside batched shell calls, and sorts
  by modification time because the file someone is asking about is usually one
  that was touched recently.
  """
  @behaviour Troupe.Tool

  alias Troupe.Tool.{Bound, Context}
  alias Troupe.Workspace

  @impl true
  def name, do: "glob"

  @impl true
  def description,
    do:
      "Find files whose path matches a glob (`**/*.ex`, `lib/**/*_test.exs`), most recently modified first. Use this instead of shelling out to `find`. Returns paths only; use `grep` to search contents."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Glob such as lib/**/*.ex"},
        "path" => %{
          "type" => "string",
          "description" => "Directory to search from, relative to the workspace"
        },
        "offset" => %{"type" => "integer", "description" => "First path to return (1-based)"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of paths"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(%{"pattern" => pattern} = args, ctx) when is_binary(pattern) do
    base = Map.get(args, "path") || "."

    case Workspace.resolve_readable(ctx.workspace, base, Context.read_roots(ctx)) do
      {:ok, dir} ->
        limits = Context.limits(ctx)
        offset = max(Map.get(args, "offset") || 1, 1)
        limit = max(Map.get(args, "limit") || limits.list_items, 1)
        root = if String.starts_with?(dir, ctx.workspace), do: ctx.workspace, else: dir

        files =
          dir
          |> Path.join(pattern)
          |> Path.wildcard(match_dot: true)
          |> Enum.reject(&excluded?(&1, root))
          |> Enum.map(&{&1, mtime(&1)})
          |> Enum.sort_by(fn {path, mtime} -> {-mtime, path} end)
          |> Enum.map(fn {path, _} -> Path.relative_to(path, root) end)

        case files do
          [] ->
            {:ok, "no files match #{pattern}"}

          files ->
            {:ok,
             files
             |> Bound.items(offset, limit)
             |> Bound.render(fn o ->
               ~s|Call glob(pattern: #{inspect(pattern)}, offset: #{o.first}, limit: #{limit}) for more, or narrow the pattern.|
             end)}
        end

      {:error, _} ->
        {:error, "path escapes the workspace and the readable roots: #{base}"}
    end
  end

  def run(_args, _ctx), do: {:error, "pattern is required"}

  # A directory is not a match, and neither is anything under .git or a sibling
  # worktree: both are full of paths that look like the file being searched for.
  defp excluded?(path, root) do
    rel = Path.relative_to(path, root)

    File.dir?(path) or rel == ".git" or String.starts_with?(rel, ".git/") or
      String.starts_with?(rel, ".troupe/worktrees")
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> 0
    end
  end
end
