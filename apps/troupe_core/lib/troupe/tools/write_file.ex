defmodule Troupe.Tools.WriteFile do
  @moduledoc "Create or overwrite a file, announcing the write to the watcher first."

  @behaviour Troupe.Tool

  alias Troupe.{Tool, Watch, Workspace}

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
        "content" => %{"type" => "string", "description" => "The complete new contents."}
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
        {:ok,
         "Wrote #{Workspace.relative(ctx.workspace, resolved)} (#{byte_size(content)} bytes)."}
      else
        {:error, reason} -> {:error, "Could not write #{path}: #{:file.format_error(reason)}"}
      end
    end
  end
end
