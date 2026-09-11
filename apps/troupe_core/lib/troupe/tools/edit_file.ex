defmodule Troupe.Tools.EditFile do
  @moduledoc """
  Exact string replacement that fails loudly on zero or multiple matches.

  Failing is the feature: a model that edited the wrong occurrence, or a file that
  has changed since it was read, must find out on this turn rather than three turns
  later. The file's existing line endings are preserved, so editing one line of a
  CRLF file does not rewrite the whole file to LF.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Tool, Watch, Workspace}

  @impl Troupe.Tool
  def name, do: "edit_file"

  @impl Troupe.Tool
  def description do
    """
    Replace an exact string in a file with another. The old string must appear
    exactly once — include enough surrounding lines to make it unique. Fails if it
    appears zero times or more than once, and changes nothing in that case.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the workspace root."},
        "old_string" => %{
          "type" => "string",
          "description" => "Exact text to replace, unique in the file."
        },
        "new_string" => %{"type" => "string", "description" => "Replacement text."}
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, path} <- Tool.fetch_string(args, "path"),
         {:ok, old} <- Tool.fetch_string(args, "old_string"),
         {:ok, new} <- Tool.fetch_string(args, "new_string"),
         {:ok, resolved} <- Workspace.resolve(ctx.workspace, path),
         {:ok, contents} <- read(resolved),
         {:ok, updated} <- replace(contents, old, new) do
      Watch.expect_write(ctx.watcher, resolved, updated)

      case File.write(resolved, updated) do
        :ok ->
          {:ok, "Edited #{Workspace.relative(ctx.workspace, resolved)}."}

        {:error, reason} ->
          {:error, "Could not write #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, {:enoent, path}}
      {:error, reason} -> {:error, "Could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp replace(contents, old, new) do
    # Normalise the needle and the replacement to the file's own line endings, so a
    # model that sends LF can still edit a CRLF file, and the result stays CRLF.
    eol = detect_eol(contents)
    old = to_eol(old, eol)
    new = to_eol(new, eol)

    case count_matches(contents, old) do
      1 -> {:ok, String.replace(contents, old, new, global: false)}
      0 -> {:error, {:no_match, old}}
      n -> {:error, {:multiple_matches, n, old}}
    end
  end

  defp count_matches(_contents, ""), do: 0
  defp count_matches(contents, needle), do: length(:binary.matches(contents, needle))

  @doc false
  @spec detect_eol(String.t()) :: :crlf | :lf
  def detect_eol(contents) do
    if String.contains?(contents, "\r\n"), do: :crlf, else: :lf
  end

  defp to_eol(text, :lf), do: String.replace(text, "\r\n", "\n")

  defp to_eol(text, :crlf) do
    text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")
  end
end
