defmodule Troupe.Watch.Markers do
  @moduledoc """
  Finds Aider-style AI comments: comments in any common syntax that start or
  end with `AI`, `AI!` (change request) or `AI?` (question), case-insensitive.
  """

  @type marker :: %{line: pos_integer(), text: String.t(), kind: :change | :question | :context}

  @comment ~r{(?:#|//|--|;|%|/\*|<!--)\s*(.*?)\s*(?:\*/|-->)?\s*$}

  @spec scan(String.t()) :: [marker()]
  def scan(content) when is_binary(content) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      case Regex.run(@comment, line) do
        [_, text] ->
          case classify(String.trim(text)) do
            nil -> []
            kind -> [%{line: n, text: String.trim(text), kind: kind}]
          end

        nil ->
          []
      end
    end)
  end

  @spec classify(String.t()) :: :change | :question | :context | nil
  def classify(text) do
    cond do
      text =~ ~r/^ai!(\s|$)/i or text =~ ~r/(^|\s)ai!$/i -> :change
      text =~ ~r/^ai\?(\s|$)/i or text =~ ~r/(^|\s)ai\?$/i -> :question
      text =~ ~r/^ai(\s|$)/i or text =~ ~r/(^|\s)ai$/i -> :context
      true -> nil
    end
  end

  @doc "Surrounding code for a marker (±3 lines)."
  @spec context(String.t(), pos_integer()) :: String.t()
  def context(content, line) do
    lines = String.split(content, ~r/\r?\n/)
    from = max(line - 4, 0)

    lines
    |> Enum.slice(from, 7)
    |> Enum.with_index(from + 1)
    |> Enum.map_join("\n", fn {l, n} -> "#{n}: #{l}" end)
  end
end
