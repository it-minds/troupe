defmodule Troupe.Frontmatter do
  @moduledoc """
  Splits a `---`-delimited YAML frontmatter block from a markdown body.

  Shared by `Troupe.Agents.Definition` (agent profiles) and `Troupe.Memory`
  (the project brief). Content with no frontmatter is not an error: it parses
  as an empty map plus the whole content as the body.
  """

  @spec split(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def split(content) when is_binary(content) do
    with {:ok, front, body} <- split_raw(content),
         {:ok, meta} <- parse_yaml(front) do
      {:ok, meta, body}
    end
  end

  defp split_raw("---" <> rest) do
    case String.split(rest, ~r/\r?\n---[ \t]*(\r?\n|$)/, parts: 2) do
      [front, body] -> {:ok, front, body}
      _ -> {:error, :unterminated_frontmatter}
    end
  end

  defp split_raw(content), do: {:ok, "", content}

  defp parse_yaml(""), do: {:ok, %{}}

  defp parse_yaml(front) do
    case YamlElixir.read_from_string(front) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, nil} -> {:ok, %{}}
      {:ok, _other} -> {:error, :frontmatter_not_a_map}
      {:error, reason} -> {:error, reason}
    end
  end
end
