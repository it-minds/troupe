defmodule Troupe.Tools.Glob do
  @moduledoc """
  Find files by name, most recently modified first.

  `list_files` already globs, but it sorts by path and is meant for surveying a
  directory; this answers "where is the file called X", which is what `find` was being
  used for inside batched shell calls, and sorts by modification time because the file
  someone is asking about is usually one that was touched recently.
  """

  @behaviour Troupe.Tool

  alias Troupe.Tool
  alias Troupe.Workspace

  @default_limit 50

  @impl Troupe.Tool
  def name, do: "glob"

  @impl Troupe.Tool
  def description do
    "Find files whose path matches a glob (`**/*.ex`, `lib/**/*_test.exs`), most recently " <>
      "modified first. Use this instead of shelling out to `find`. Returns paths only; use " <>
      "`grep` to search contents."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Glob such as lib/**/*.ex."},
        "path" => %{"type" => "string", "description" => "Directory to search from, relative to the workspace."},
        "offset" => %{"type" => "integer", "description" => "First path to return (1-based)."},
        "limit" => %{"type" => "integer", "description" => "Maximum number of paths (default #{@default_limit})."}
      },
      "required" => ["pattern"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, pattern} <- Tool.fetch_string(args, "pattern"),
         {:ok, dir} <- Workspace.resolve(ctx.workspace, Map.get(args, "path") || ".", :read) do
      offset = max(Tool.fetch_int(args, "offset", 1) || 1, 1)
      limit = max(Tool.fetch_int(args, "limit", @default_limit) || @default_limit, 1)

      files =
        dir
        |> Path.join(pattern)
        |> Path.wildcard(match_dot: true)
        |> Enum.reject(&excluded?(&1, ctx))
        |> Enum.map(&{&1, mtime(&1)})
        |> Enum.sort_by(fn {path, mtime} -> {-mtime, path} end)
        |> Enum.map(fn {path, _} -> Workspace.relative(ctx.workspace, path) end)

      {:ok, render(files, pattern, offset, limit)}
    end
  end

  defp render([], pattern, _offset, _limit), do: "no files match #{pattern}"

  defp render(files, pattern, offset, limit) do
    total = length(files)
    shown = files |> Enum.drop(offset - 1) |> Enum.take(limit)
    last = min(offset + limit - 1, total)
    body = Enum.join(shown, "\n")

    if last >= total do
      body
    else
      body <>
        "\n[… paths #{last + 1}–#{total} of #{total} omitted. Call glob(pattern: #{inspect(pattern)}, " <>
        "offset: #{last + 1}, limit: #{limit}) for more, or narrow the pattern.]"
    end
  end

  defp excluded?(path, ctx) do
    rel = Workspace.relative(ctx.workspace, path)

    File.dir?(path) or rel == ".git" or String.starts_with?(rel, ".git/") or
      String.contains?(rel, "/.git/")
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> 0
    end
  end
end
