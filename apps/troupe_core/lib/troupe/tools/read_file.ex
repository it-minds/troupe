defmodule Troupe.Tools.ReadFile do
  @moduledoc "Read a file, optionally a line range, with the output capped."

  @behaviour Troupe.Tool

  alias Troupe.{Tool, Workspace}
  alias Troupe.Tools.Output

  @default_limit 2_000

  @impl Troupe.Tool
  def name, do: "read_file"

  @impl Troupe.Tool
  def description do
    """
    Read a file from the workspace. Returns the contents with 1-based line numbers.
    Use `offset` and `limit` for a range; large files are truncated and say so.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the workspace root."},
        "offset" => %{"type" => "integer", "description" => "1-based first line to read."},
        "limit" => %{"type" => "integer", "description" => "How many lines to read."}
      },
      "required" => ["path"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, path} <- Tool.fetch_string(args, "path"),
         {:ok, resolved} <- Workspace.resolve_readable(ctx.workspace, path, Workspace.read_roots(ctx)),
         {:ok, contents} <- read(resolved) do
      offset = max(Tool.fetch_int(args, "offset", 1), 1)
      limit = max(Tool.fetch_int(args, "limit", @default_limit), 1)
      {:ok, render(contents, offset, limit, ctx.config)}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, {:enoent, path}}
      {:error, :eisdir} -> {:error, "#{path} is a directory, not a file."}
      {:error, reason} -> {:error, "Could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp render(contents, offset, limit, config) do
    lines = String.split(contents, ~r/\r?\n/)
    total = length(lines)

    selected =
      lines
      |> Enum.drop(offset - 1)
      |> Enum.take(limit)
      |> Enum.with_index(offset)
      |> Enum.map_join("\n", fn {line, number} -> "#{number}\t#{line}" end)

    body = Output.cap(selected, cap(config))
    shown_to = min(offset + limit - 1, total)

    if offset > 1 or shown_to < total do
      "(lines #{offset}-#{shown_to} of #{total})\n" <> body
    else
      body
    end
  end

  defp cap(nil), do: 60_000
  defp cap(config), do: config.tool_output_limit
end
