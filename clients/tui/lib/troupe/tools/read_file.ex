defmodule Troupe.Tools.ReadFile do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Workspace

  @max_bytes 100_000

  @impl true
  def name, do: "read_file"

  @impl true
  def description,
    do:
      "Read a file from the workspace. Returns numbered lines. Use `offset` (1-based line) and `limit` for large files. Output is capped at #{@max_bytes} bytes."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the workspace root"},
        "offset" => %{"type" => "integer", "description" => "First line to return (1-based)"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of lines"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(%{"path" => path} = args, ctx) do
    with {:ok, abs} <- Workspace.resolve(ctx.workspace, path),
         {:ok, content} <- File.read(abs) do
      offset = max(Map.get(args, "offset", 1) || 1, 1)
      limit = Map.get(args, "limit") || 2000

      lines =
        content
        |> String.split(~r/\r?\n/)
        |> Enum.with_index(1)
        |> Enum.drop(offset - 1)
        |> Enum.take(limit)
        |> Enum.map_join("\n", fn {line, n} ->
          "#{String.pad_leading(Integer.to_string(n), 5)}\t#{line}"
        end)

      {:ok, cap(lines)}
    else
      {:error, :outside_workspace} -> {:error, "path escapes the workspace: #{path}"}
      {:error, :invalid_path} -> {:error, "invalid path: #{path}"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def run(_, _), do: {:error, "path is required"}

  defp cap(text) when byte_size(text) > @max_bytes,
    do: binary_part(text, 0, @max_bytes) <> "\n[truncated]"

  defp cap(text), do: text
end
