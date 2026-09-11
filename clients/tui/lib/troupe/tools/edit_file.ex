defmodule Troupe.Tools.EditFile do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Session.{Locks, Watcher}
  alias Troupe.Tool.Diff
  alias Troupe.Workspace

  @impl true
  def name, do: "edit_file"

  @impl true
  def description,
    do:
      "Replace an exact string in a file with another. Fails if the old string matches zero or more than one time. Preserves the file's line endings. In shared isolation the path is locked during the edit."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "old_string" => %{"type" => "string"},
        "new_string" => %{"type" => "string"}
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def default_permission, do: :ask

  @impl true
  def preview(%{"path" => path} = args, ctx) do
    case apply_edit(ctx, path, args["old_string"], args["new_string"]) do
      {:ok, old, new} -> Diff.unified(path, old, new)
      {:error, reason} -> "edit_file #{path}: #{reason}"
    end
  end

  def preview(args, _ctx), do: inspect(args)

  @impl true
  def run(%{"path" => path, "old_string" => old, "new_string" => new}, ctx)
      when is_binary(old) and is_binary(new) do
    case Workspace.resolve(ctx.workspace, path) do
      {:ok, abs} ->
        Locks.with_lock(ctx.session_id, abs, ctx.agent_path, fn ->
          with {:ok, _before, after_content} <- apply_edit(ctx, path, old, new) do
            Watcher.expect_write(ctx.session_id, abs, after_content)

            case File.write(abs, after_content) do
              :ok -> {:ok, "edited #{path}"}
              {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
            end
          end
        end)

      {:error, :outside_workspace} ->
        {:error, "path escapes the workspace: #{path}"}

      {:error, :invalid_path} ->
        {:error, "invalid path: #{path}"}
    end
  end

  def run(_, _), do: {:error, "path, old_string and new_string are required"}

  defp apply_edit(ctx, path, old, new) do
    with {:ok, abs} <- Workspace.resolve(ctx.workspace, path),
         {:ok, content} <- read(abs, path) do
      crlf? = String.contains?(content, "\r\n")
      lf_content = if crlf?, do: String.replace(content, "\r\n", "\n"), else: content
      lf_old = String.replace(old, "\r\n", "\n")
      lf_new = String.replace(new, "\r\n", "\n")

      case count(lf_content, lf_old) do
        0 ->
          {:error, "old_string not found in #{path}"}

        1 ->
          replaced = String.replace(lf_content, lf_old, lf_new, global: false)
          replaced = if crlf?, do: String.replace(replaced, "\n", "\r\n"), else: replaced
          {:ok, content, replaced}

        n ->
          {:error,
           "old_string matches #{n} times in #{path}; include more context to make it unique"}
      end
    end
  end

  defp read(abs, path) do
    case File.read(abs) do
      {:ok, c} -> {:ok, c}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp count(_content, ""), do: 0
  defp count(content, needle), do: content |> String.split(needle) |> length() |> Kernel.-(1)
end
