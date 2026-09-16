defmodule Troupe.Remote.Diff do
  @moduledoc """
  Structured diffs, as the unified-diff text the transcript already renders.

  The wire shape is `{path, hunks: [{old_start, old_lines, new_start,
  new_lines, lines: [{op, text}]}]}`; keeping it structured on the wire is the
  server's business, and turning it into `@@`/`+`/`-` here means the pane, the
  approval preview and `/copy` all treat a remote diff exactly like a local one.
  """

  @doc "Renders one structured diff. Anything unrecognisable comes back as nil."
  @spec render(map() | nil) :: String.t() | nil
  def render(%{} = diff) do
    hunks = diff["hunks"] || diff[:hunks] || []
    path = diff["path"] || diff[:path]

    case Enum.flat_map(List.wrap(hunks), &hunk/1) do
      [] -> nil
      lines -> Enum.join(header(path) ++ lines, "\n")
    end
  end

  def render(_diff), do: nil

  defp header(nil), do: []
  defp header(path), do: ["--- a/#{path}", "+++ b/#{path}"]

  defp hunk(%{} = hunk) do
    old_start = get(hunk, :old_start, 0)
    old_lines = get(hunk, :old_lines, 0)
    new_start = get(hunk, :new_start, 0)
    new_lines = get(hunk, :new_lines, 0)

    marker = "@@ -#{old_start},#{old_lines} +#{new_start},#{new_lines} @@"
    [marker | Enum.map(List.wrap(get(hunk, :lines, [])), &line/1)]
  end

  defp hunk(_other), do: []

  defp line(%{} = line) do
    text = get(line, :text, "")

    case get(line, :op, " ") do
      "+" -> "+" <> text
      "-" -> "-" <> text
      "add" -> "+" <> text
      "del" -> "-" <> text
      "remove" -> "-" <> text
      _ -> " " <> text
    end
  end

  defp line(other) when is_binary(other), do: other
  defp line(_other), do: ""

  defp get(map, key, default) do
    case Map.get(map, to_string(key), Map.get(map, key)) do
      nil -> default
      value -> value
    end
  end
end
