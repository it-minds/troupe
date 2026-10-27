defmodule Troupe.Tools.WriteFile do
  @moduledoc """
  Create or overwrite a file, announcing the write to the watcher first.

  `deliverable: true` says the file is what the person asked for: the write is then
  followed by a `file_ready` event naming it, which the person's client offers to save (the
  desktop app's Save…, the terminal's path or `/save`). An argument here rather than a tool
  of its own, as a tool would be a name, a description and a schema in every prompt.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Session, Tool, Watch, Workspace}
  alias Troupe.Session.Log

  @impl Troupe.Tool
  def name, do: "write_file"

  @impl Troupe.Tool
  def description do
    """
    Write a file, creating it and any missing parent directories, replacing it if it
    exists. Prefer `edit_file` for changing part of an existing file: it fails when
    the file is not what you expected, which is feedback you want.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the workspace root."},
        "content" => %{"type" => "string", "description" => "The complete new contents."},
        "deliverable" => %{"type" => "boolean", "description" => "True for a file the person asked for."}
      },
      "required" => ["path", "content"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, path} <- Tool.fetch_string(args, "path"),
         {:ok, content} <- Tool.fetch_string(args, "content"),
         {:ok, resolved} <- Workspace.resolve(ctx.workspace, path, :write) do
      # Tell the watcher before touching disk, or our own write triggers us.
      Watch.expect_write(ctx.watcher, resolved, content)

      with :ok <- File.mkdir_p(Path.dirname(resolved)),
           :ok <- File.write(resolved, content) do
        relative = Workspace.relative(ctx.workspace, resolved)
        :ok = maybe_ready(args["deliverable"], ctx, relative, resolved, content)
        {:ok, "Wrote #{relative} (#{byte_size(content)} bytes)."}
      else
        {:error, reason} -> {:error, "Could not write #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp maybe_ready(true, %{session_id: id} = ctx, relative, resolved, content) when is_binary(id),
    do: ready(ctx, relative, resolved, content)

  defp maybe_ready(_deliverable, _ctx, _relative, _resolved, _content), do: :ok

  # What the person's client offers to save: the file by the path `fs.read` takes, with the
  # hash that read answers, and on a session that runs on this machine where it is here.
  defp ready(ctx, relative, resolved, content) do
    data =
      %{
        "path" => String.replace(relative, "\\", "/"),
        "size" => byte_size(content),
        "hash" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      }
      |> put_local(ctx.session_id, resolved)

    _ = Log.append(ctx.session_id, ctx.agent_path || Session.root_path(), :file_ready, data)
    :ok
  end

  defp put_local(data, session_id, resolved) do
    case Session.resolved(session_id) do
      %{kind: :team} -> data
      _local -> Map.put(data, "local_path", resolved)
    end
  end
end
