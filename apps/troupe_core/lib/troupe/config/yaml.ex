defmodule Troupe.Config.Yaml do
  @moduledoc """
  Writes the subset of YAML a config file is made of: maps, lists, strings, numbers,
  booleans and nulls.

  `yaml_elixir` only reads. The encoding is deliberately plain — block maps, keys in
  sorted order, every string double-quoted with JSON's escapes, which YAML accepts
  verbatim — so the output reads back to exactly the map that went in, whatever the
  string holds: a `{env:VAR}` reference, a colon, a leading `!`, a `#`. What it cannot
  keep is what a map does not hold: comments and the original key order.

  `edit_list/4` is the other way to write: one top-level list changed line by line in
  the file's own text, for a change as small as adding a path to `trusted_workspaces`,
  which a person should not lose their comments over.
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

  # -- one list, in place ---------------------------------------------------------

  @doc """
  Change the top-level list `key` in a file's text and leave every other line as it
  was: the items `keep?` says no to are removed, and `add` is appended, one item a
  line, indented like the items already there.

  A list written one item a line keeps its comments and the items that stay keep their
  spelling. One written another way — in brackets, say — is written out again one item
  a line, and only its own comments are lost; a file without the key gets it at the
  end. The answer is checked by reading it back: `:error` unless it is the same map with
  only that list changed, so a shape this does not follow is never half edited.
  """
  @spec edit_list(String.t(), String.t(), (term() -> boolean()), [term()]) :: {:ok, String.t()} | :error
  def edit_list(text, key, keep?, add) do
    {bom, body} = split_bom(text)
    newline = if String.contains?(body, "\r\n"), do: "\r\n", else: "\n"
    lines = body |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))

    with {:ok, before} <- read_map(body),
         {:ok, old} <- list_value(before, key) do
      if add == [] and not Map.has_key?(before, key) do
        {:ok, text}
      else
        expected = Map.put(before, key, Enum.filter(old, keep?) ++ add)
        edit_checked(lines, key, {old, keep?, add}, expected, {bom, newline})
      end
    end
  end

  # Read back, the edit must be the map it was meant to make, or it is not made.
  defp edit_checked(lines, key, change, expected, {bom, newline}) do
    with {:ok, lines} <- edit_lines(lines, key, change),
         edited = Enum.join(lines, newline),
         {:ok, ^expected} <- read_map(edited) do
      {:ok, bom <> edited}
    else
      _ -> :error
    end
  end

  defp split_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {<<0xEF, 0xBB, 0xBF>>, rest}
  defp split_bom(text), do: {"", text}

  defp read_map(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, nil} -> {:ok, %{}}
      _ -> :error
    end
  end

  defp list_value(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, []}
      list when is_list(list) -> {:ok, list}
      _other -> :error
    end
  end

  defp edit_lines(lines, key, change) do
    pattern = ~r/^(?:#{Regex.escape(key)}|"#{Regex.escape(key)}"|'#{Regex.escape(key)}')\s*:(?=\s|$)/

    case lines |> Enum.with_index() |> Enum.filter(fn {line, _i} -> line =~ pattern end) do
      [] -> {:ok, append(lines, key, elem(change, 2))}
      [{_line, i}] -> {:ok, in_place(lines, i, change)}
      _twice -> :error
    end
  end

  defp append(lines, key, add) do
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    lines ++ ["#{key}:"] ++ Enum.map(add, &("  - " <> scalar(&1))) ++ [""]
  end

  # The key's own lines are the ones after it until the next line at the left margin
  # that is not an item of it; comments and blank lines at the end of them belong to
  # whatever follows.
  defp in_place(lines, i, {old, keep?, add}) do
    {head, [key_line | rest]} = Enum.split(lines, i)
    {own, tail} = Enum.split_while(rest, &belongs?/1)
    {trailing, own} = own |> Enum.reverse() |> Enum.split_while(&(not content?(&1)))
    own = Enum.reverse(own)
    [name, value] = String.split(key_line, ":", parts: 2)

    edited =
      if value =~ ~r/^\s*(#.*)?$/ and Enum.all?(own, &(not content?(&1) or item(&1) != :error)),
        do: block(name, value, own, keep?, add),
        else: rewritten(name, Enum.filter(old, keep?) ++ add)

    head ++ edited ++ Enum.reverse(trailing) ++ tail
  end

  defp block(name, value, own, keep?, add) do
    kept = Enum.reject(own, &dropped?(&1, keep?))
    prefix = Enum.find_value(own, "  - ", &prefix/1)
    added = Enum.map(add, &(prefix <> scalar(&1)))
    value = String.trim_trailing(value)

    case Enum.find_index(Enum.reverse(kept), &content?/1) do
      nil when added == [] ->
        [name <> ": []" <> value | kept]

      nil ->
        [name <> ":" <> value | kept ++ added]

      from_end ->
        {above, below} = Enum.split(kept, length(kept) - from_end)
        [name <> ":" <> value | above ++ added ++ below]
    end
  end

  defp dropped?(line, keep?) do
    case item(line) do
      {:ok, _prefix, value} -> not keep?.(value)
      :error -> false
    end
  end

  defp prefix(line) do
    case item(line) do
      {:ok, prefix, _value} -> prefix
      :error -> nil
    end
  end

  # One item a line: `- value`, with any comment after it. What the item says is what
  # YAML reads it as, so quoting and escapes are its business, not this module's.
  defp item(line) do
    with [_all, prefix] <- Regex.run(~r/^(\s*-\s+)\S/, line),
         {:ok, [value]} <- YamlElixir.read_from_string(String.trim_leading(line)) do
      {:ok, prefix, value}
    else
      _ -> :error
    end
  end

  defp rewritten(name, []), do: [name <> ": []"]
  defp rewritten(name, items), do: [name <> ":" | Enum.map(items, &("  - " <> scalar(&1)))]

  defp belongs?(line),
    do: not content?(line) or line =~ ~r/^\s/ or line =~ ~r/^-(\s|$)/ or line =~ ~r/^[\]}]/

  defp content?(line) do
    trimmed = String.trim(line)
    trimmed != "" and not String.starts_with?(trimmed, "#")
  end
end
