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
      "Read one file (`path`) or several at once (`paths`). Returns numbered lines, each file under a `===== path =====` header. Prefer one call with `paths` over several calls when you already know which files you want. Use `offset` (1-based line) and `limit` to page a single file: a read that does not reach the end says so and names the next offset."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the workspace root"},
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Several paths to read in one call, instead of `path`"
        },
        "offset" => %{"type" => "integer", "description" => "First line to return (1-based)"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of lines per file"}
      }
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  # Reading several files was the commonest thing the shell tool was used for
  # that a native tool already did: 43% of read-only shell calls chained
  # commands, most of them `cat a b c` with `echo ===` between. One call that
  # takes a list is that, without the shell.
  def run(%{"paths" => paths}, ctx) when is_list(paths) and paths != [] do
    limits = Context.limits(ctx)

    body =
      paths
      |> Enum.filter(&is_binary/1)
      |> Enum.map_join("\n\n", fn path ->
        "===== #{path} =====\n" <> one(path, 1, limits.file_lines, ctx)
      end)

    text = Bound.sanitize(body)

    {:ok,
     Outputs.store_and_mark(
       ctx.session_id,
       text,
       Bound.chars(text, limits.max_chars),
       limits.file_lines
     )}
  end

  def run(%{"paths" => _}, _ctx), do: {:error, "paths must be a non-empty list of strings"}

  def run(%{"path" => path} = args, ctx) do
    with {:ok, abs} <- Workspace.resolve_readable(ctx.workspace, path, Context.read_roots(ctx)),
         {:ok, content} <- File.read(abs) do
      limits = Context.limits(ctx)
      offset = max(Map.get(args, "offset", 1) || 1, 1)
      limit = max(Map.get(args, "limit") || limits.file_lines, 1)

      {:ok, bound(numbered(content), path, offset, limit, limits, ctx)}
    else
      {:error, :outside_workspace} -> {:error, outside(path, ctx)}
      {:error, :invalid_path} -> {:error, "invalid path: #{path}"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def run(_, _), do: {:error, "path or paths is required"}

  # One file inside a multi-file read. A failure here is reported in place rather
  # than failing the call: a list of five files where one has been deleted should
  # still return the other four.
  defp one(path, offset, limit, ctx) do
    with {:ok, abs} <- Workspace.resolve_readable(ctx.workspace, path, Context.read_roots(ctx)),
         {:ok, content} <- File.read(abs) do
      content
      |> numbered()
      |> Bound.window(offset, limit)
      |> Bound.render(fn o ->
        ~s|Call read_file(path: "#{path}", offset: #{o.first}, limit: #{limit}) for more.|
      end)
    else
      {:error, :outside_workspace} -> outside(path, ctx)
      {:error, :invalid_path} -> "invalid path: #{path}"
      {:error, reason} -> "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp numbered(content) do
    content
    |> Bound.sanitize()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, n} ->
      "#{String.pad_leading(Integer.to_string(n), 5)}\t#{line}"
    end)
  end

  # Naming the readable roots turns a refusal into something the model can act
  # on: without them it retries the same path, or falls back to `shell`.
  defp outside(path, ctx) do
    case Context.read_roots(ctx) do
      [] ->
        "path escapes the workspace: #{path}"

      roots ->
        "path escapes the workspace and the readable roots (#{Enum.join(roots, ", ")}): #{path}"
    end
  end

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
