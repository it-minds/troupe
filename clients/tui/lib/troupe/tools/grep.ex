defmodule Troupe.Tools.Grep do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.OS
  alias Troupe.Tool.{Bound, Context}
  alias Troupe.Workspace

  @max_bytes 5_000_000

  @impl true
  def name, do: "grep"

  @impl true
  def description,
    do:
      "Search file contents with a regular expression. Uses ripgrep when installed and a built-in search otherwise. Returns `path:line:text` matches, capped per call; use `offset` (1-based match) and `limit` to page through the rest."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string"},
        "path" => %{
          "type" => "string",
          "description" => "Directory or file to search, relative to the workspace"
        },
        "glob" => %{"type" => "string", "description" => "Only search files matching this glob"},
        "offset" => %{"type" => "integer", "description" => "First match to return (1-based)"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of matches"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(%{"pattern" => pattern} = args, ctx) do
    base = Map.get(args, "path") || "."

    case Workspace.resolve(ctx.workspace, base) do
      {:ok, dir} ->
        if System.find_executable("rg") do
          ripgrep(pattern, dir, args, ctx)
        else
          builtin(pattern, dir, args, ctx)
        end

      {:error, _} ->
        {:error, "path escapes the workspace: #{base}"}
    end
  end

  def run(_, _), do: {:error, "pattern is required"}

  defp ripgrep(pattern, dir, args, ctx) do
    glob = args["glob"]
    glob_args = if glob, do: ["--glob", glob], else: []

    rg_args =
      ["--line-number", "--no-heading", "--color", "never", "-e", pattern] ++ glob_args ++ [dir]

    case OS.Process.run("rg", rg_args,
           cd: ctx.workspace,
           timeout_ms: 30_000,
           max_output: @max_bytes
         ) do
      {:ok, out, 0} -> {:ok, out |> relativize(ctx.workspace) |> bound(args, ctx)}
      {:ok, _out, 1} -> {:ok, "no matches"}
      {:ok, out, _} -> {:error, "rg failed: #{out}"}
      {:error, :timeout, _} -> {:error, "grep timed out"}
    end
  end

  defp builtin(pattern, dir, args, ctx) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        files =
          if File.dir?(dir),
            do: Path.wildcard(Path.join(dir, args["glob"] || "**/*"), match_dot: true),
            else: [dir]

        out =
          files
          |> Enum.reject(&(String.contains?(&1, "/.git/") or File.dir?(&1)))
          |> Enum.flat_map(&matches(&1, re, ctx.workspace))
          |> Enum.join("\n")

        if out == "", do: {:ok, "no matches"}, else: {:ok, bound(out, args, ctx)}

      {:error, {msg, _}} ->
        {:error, "invalid regex: #{msg}"}
    end
  end

  defp matches(file, re, root) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split(~r/\r?\n/)
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(re, line) end)
        |> Enum.map(fn {line, n} -> "#{Path.relative_to(file, root)}:#{n}:#{line}" end)

      _ ->
        []
    end
  end

  defp relativize(out, root), do: String.replace(out, root <> "/", "")

  # A search is idempotent and cheap to repeat, so the omitted matches are not
  # stored: the marker names the same call with the next offset.
  defp bound(out, args, ctx) do
    limits = Context.limits(ctx)
    offset = max(Map.get(args, "offset") || 1, 1)
    limit = max(Map.get(args, "limit") || limits.list_items, 1)

    out
    |> Bound.sanitize()
    |> String.split("\n", trim: true)
    |> Bound.items(offset, limit)
    |> Bound.render(fn o ->
      ~s|Call grep(pattern: #{inspect(args["pattern"])}, offset: #{o.first}, limit: #{limit}) for more, or narrow the pattern.|
    end)
  end
end
