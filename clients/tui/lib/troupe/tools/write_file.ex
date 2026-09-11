defmodule Troupe.Tools.WriteFile do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Session.{Locks, Watcher}
  alias Troupe.Tool.Diff
  alias Troupe.Workspace

  @impl true
  def name, do: "write_file"

  @impl true
  def description,
    do:
      "Create or overwrite a file in the workspace with the given content. Parent directories are created. In shared isolation the path is locked for the duration of the write; contention returns an error naming the holder."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def default_permission, do: :ask

  @impl true
  def preview(%{"path" => path, "content" => content}, ctx) do
    old =
      case Workspace.resolve(ctx.workspace, path) do
        {:ok, abs} ->
          File.read(abs)
          |> case do
            {:ok, c} -> c
            _ -> ""
          end

        _ ->
          ""
      end

    Diff.unified(path, old, content)
  end

  def preview(args, _ctx), do: inspect(args)

  @impl true
  def run(%{"path" => path, "content" => content}, ctx) when is_binary(content) do
    case Workspace.resolve(ctx.workspace, path) do
      {:ok, abs} ->
        Locks.with_lock(ctx.session_id, abs, ctx.agent_path, fn ->
          Watcher.expect_write(ctx.session_id, abs, content)
          File.mkdir_p!(Path.dirname(abs))

          case File.write(abs, content) do
            :ok -> {:ok, "wrote #{byte_size(content)} bytes to #{path}"}
            {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
          end
        end)

      {:error, :outside_workspace} ->
        {:error, "path escapes the workspace: #{path}"}

      {:error, :invalid_path} ->
        {:error, "invalid path: #{path}"}
    end
  end

  def run(_, _), do: {:error, "path and content are required"}
end
