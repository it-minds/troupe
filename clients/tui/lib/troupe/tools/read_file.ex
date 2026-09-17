defmodule Troupe.Tools.ReadFile do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Session.Outputs
  alias Troupe.Tool.{Bound, Context}
  alias Troupe.Workspace

  @impl true
  def name, do: "read_file"

  @impl true
  def description,
    do:
      "Read a file from the workspace. Returns numbered lines. Use `offset` (1-based line) and `limit` to page: a read that does not reach the end of the file says so and names the next offset."

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
      limits = Context.limits(ctx)
      offset = max(Map.get(args, "offset", 1) || 1, 1)
      limit = max(Map.get(args, "limit") || limits.file_lines, 1)

      numbered =
        content
        |> Bound.sanitize()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {line, n} ->
          "#{String.pad_leading(Integer.to_string(n), 5)}\t#{line}"
        end)

      {:ok, bound(numbered, path, offset, limit, limits, ctx)}
    else
      {:error, :outside_workspace} -> {:error, "path escapes the workspace: #{path}"}
      {:error, :invalid_path} -> {:error, "invalid path: #{path}"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def run(_, _), do: {:error, "path is required"}

  # A file read is idempotent, so a line window needs nothing stored: the next
  # window is one more `read_file` away. The character cap is the backstop for a
  # file with no line structure — one minified line, a blob of base64 — where a
  # line window bounds nothing and there is no next offset to name, so that one
  # is stored and paged with `read_output`.
  defp bound(numbered, path, offset, limit, limits, ctx) do
    {text, omission} = Bound.window(numbered, offset, limit)

    case Bound.chars(text, limits.max_chars) do
      {capped, nil} ->
        Bound.render({capped, omission}, fn o ->
          ~s|Call read_file(path: "#{path}", offset: #{o.first}, limit: #{limit}) for more.|
        end)

      cut ->
        Outputs.store_and_mark(ctx.session_id, text, cut, limits.file_lines)
    end
  end
end
