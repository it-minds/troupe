defmodule Troupe.Config.Yaml do
  @moduledoc """
  Writes the subset of YAML a config file is made of: maps, lists, strings, numbers,
  booleans and nulls.

  `yaml_elixir` only reads. The encoding is deliberately plain — block maps, keys in
  sorted order, every string double-quoted with JSON's escapes, which YAML accepts
  verbatim — so the output reads back to exactly the map that went in, whatever the
  string holds: a `{env:VAR}` reference, a colon, a leading `!`, a `#`. What it cannot
  keep is what a map does not hold: comments and the original key order.
  """

  @doc "The document for one map, ending in a newline."
  @spec encode(map()) :: String.t()
  def encode(map) when is_map(map) and map_size(map) == 0, do: "{}\n"
  def encode(map) when is_map(map), do: IO.iodata_to_binary(block(map, 0))

  defp block(map, indent) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> entry(key(key), value, indent) end)
  end

  defp entry(key, value, indent) when is_map(value) and map_size(value) > 0,
    do: [pad(indent), key, ":\n", block(value, indent + 2)]

  defp entry(key, [_ | _] = list, indent),
    do: [pad(indent), key, ":\n", Enum.map(list, &item(&1, indent + 2))]

  defp entry(key, value, indent), do: [pad(indent), key, ": ", scalar(value), "\n"]

  # A map inside a list puts its first key on the dash's line and the rest beneath it,
  # indented to line up — the only shape YAML reads back as one map per item.
  defp item(map, indent) when is_map(map) and map_size(map) > 0 do
    lines = IO.iodata_to_binary(block(map, indent + 2))
    skip = indent + 2
    [pad(indent), "- ", binary_part(lines, skip, byte_size(lines) - skip)]
  end

  defp item([_ | _] = list, indent), do: [pad(indent), "-\n", Enum.map(list, &item(&1, indent + 2))]
  defp item(value, indent), do: [pad(indent), "- ", scalar(value), "\n"]

  defp scalar(nil), do: "null"
  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp scalar(value) when is_map(value), do: "{}"
  defp scalar([]), do: "[]"
  defp scalar(value) when is_atom(value), do: quote_string(Atom.to_string(value))
  defp scalar(value) when is_binary(value), do: quote_string(value)

  # A bare key is only safe when it cannot be mistaken for anything else.
  defp key(key) do
    key = to_string(key)
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_.\/-]*\z/, key), do: key, else: quote_string(key)
  end

  defp quote_string(value), do: Jason.encode!(value)

  defp pad(0), do: ""
  defp pad(indent), do: String.duplicate(" ", indent)
end
