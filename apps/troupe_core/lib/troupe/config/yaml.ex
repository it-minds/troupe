defmodule Troupe.Config.Yaml do
  @moduledoc """
  Writes the subset of YAML a config file is made of: maps, lists, strings, numbers,
  booleans and nulls.

  `yaml_elixir` only reads. The encoding is deliberately plain — block maps, keys in
  sorted order, every string double-quoted with JSON's escapes, which YAML accepts
  verbatim — so the output reads back to exactly the map that went in, whatever the
  string holds: a `{env:VAR}` reference, a colon, a leading `!`, a `#`. What it cannot
  keep is what a map does not hold: comments and the original key order.

  The other way to write is to change a file's own text and nothing else, so a person
  loses no comment to a settings screen: `edit/2` makes the file read as a new map key
  by key, `put/3` sets one key, and `edit_list/4` changes one top-level list item by
  item, for a change as small as adding a path to `trusted_workspaces`.
  """

  @doc "The document for one map, ending in a newline."
  @spec encode(map()) :: String.t()
  def encode(map) when is_map(map) and map_size(map) == 0, do: "{}\n"
  def encode(map) when is_map(map), do: IO.iodata_to_binary(block(map, 0, &scalar/1))

  # `write` spells a scalar: `scalar/1` for a whole document, `plain/1` for an edit.
  defp block(map, indent, write) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> entry(key(key), value, indent, write) end)
  end

  defp entry(key, value, indent, write) when is_map(value) and map_size(value) > 0,
    do: [pad(indent), key, ":\n", block(value, indent + 2, write)]

  defp entry(key, [_ | _] = list, indent, write),
    do: [pad(indent), key, ":\n", Enum.map(list, &item(&1, indent + 2, write))]

  defp entry(key, value, indent, write), do: [pad(indent), key, ": ", write.(value), "\n"]

  # A map inside a list puts its first key on the dash's line and the rest beneath it,
  # indented to line up — the only shape YAML reads back as one map per item.
  defp item(map, indent, write) when is_map(map) and map_size(map) > 0 do
    lines = IO.iodata_to_binary(block(map, indent + 2, write))
    skip = indent + 2
    [pad(indent), "- ", binary_part(lines, skip, byte_size(lines) - skip)]
  end

  defp item([_ | _] = list, indent, write), do: [pad(indent), "-\n", Enum.map(list, &item(&1, indent + 2, write))]
  defp item(value, indent, write), do: [pad(indent), "- ", write.(value), "\n"]

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

  # A string an edit writes goes bare when it reads back as itself, and would under
  # YAML 1.1 too, where `yes` and `off` are booleans; in double quotes otherwise.
  defp plain(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9_.\/~][A-Za-z0-9_.\/~@+:-]*\z/ and not String.ends_with?(value, ":") and
         String.downcase(value) not in ~w(y n yes no on off true false null) and
         YamlElixir.read_from_string("k: " <> value) == {:ok, %{"k" => value}},
       do: value,
       else: quote_string(value)
  end

  defp plain(value), do: scalar(value)

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

  # -- keys, in place -------------------------------------------------------------

  @doc """
  Set the key at `path` — `["max_turns"]`, or a nested one, `["models", "default"]` — to
  `value` in a file's text, and leave every other line as it was: `edit/2` with the
  file's own map changed in that one place. A key that is not there is added under its
  parent, and a parent that is not there with it.
  """
  @spec put(String.t(), [String.t()], term()) :: {:ok, String.t()} | :error
  def put(text, [_ | _] = path, value) do
    with {:ok, map} <- text |> split_bom() |> elem(1) |> read_map() do
      edit(text, put_path(map, path, value))
    end
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    inner = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, put_path(inner, rest, value))
  end

  @doc """
  Change a file's text so it reads as `map`, key by key, and leave every line that
  holds no change as it was: comments, blank lines, the order of the keys and the
  spelling of every value that stays.

  A changed value is written on its key's own line, which keeps the key as it is
  spelled and any comment after it. A string goes bare when YAML reads it back as the
  same string, in double quotes when it needs them or was quoted before. A key that is
  not there is added after the last key of its map, a missing map with it; a key that
  is gone goes with the lines beneath it. A map written one key a line is edited key by
  key; any other map or list that changes is written out again under its key, one entry
  a line.

  The answer is checked by reading it back: `:error` unless it is exactly `map`, so a
  shape this does not follow is never half edited.
  """
  @spec edit(String.t(), map()) :: {:ok, String.t()} | :error
  def edit(text, map) when is_map(map) do
    {bom, body} = split_bom(text)
    newline = if String.contains?(body, "\r\n"), do: "\r\n", else: "\n"
    lines = body |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))

    with {:ok, before} <- read_map(body),
         {:ok, lines} <- edit_map(lines, indent_of(lines, 0), before, map),
         edited = Enum.join(lines, newline),
         {:ok, ^map} <- read_map(edited) do
      {:ok, bom <> edited}
    else
      _ -> :error
    end
  end

  # One map's lines, its keys at `indent`: what is gone removed, what changed changed
  # where it is, and what is new added after the map's last line.
  defp edit_map(lines, indent, old, new) do
    gone = old |> Map.keys() |> Enum.reject(&Map.has_key?(new, &1)) |> Enum.sort_by(&to_string/1)

    {changed, added} =
      new
      |> Enum.reject(fn {key, value} -> Map.fetch(old, key) === {:ok, value} end)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.split_with(fn {key, _value} -> Map.has_key?(old, key) end)

    with {:ok, lines} <- each(gone, lines, &remove(&2, indent, &1)),
         {:ok, lines} <- each(changed, lines, fn {key, value}, acc -> change(acc, indent, key, old[key], value) end) do
      {:ok, add(lines, indent, added)}
    end
  end

  defp each(items, lines, fun) do
    Enum.reduce_while(items, {:ok, lines}, fn item, {:ok, lines} ->
      case fun.(item, lines) do
        {:ok, lines} -> {:cont, {:ok, lines}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp remove(lines, indent, key) do
    with {:ok, i} <- locate(lines, indent, key) do
      {head, _key_line, _own, rest} = split_key(lines, i, indent)
      {:ok, head ++ rest}
    end
  end

  defp change(lines, indent, key, old, new) do
    with {:ok, i} <- locate(lines, indent, key),
         {head, key_line, own, rest} = split_key(lines, i, indent),
         [_line, name, after_colon] <- Regex.run(key_pattern(indent, key), key_line),
         {:ok, replaced} <- replace(name, after_colon, own, indent, old, new) do
      {:ok, head ++ replaced ++ rest}
    else
      _ -> :error
    end
  end

  # A map written one key a line beneath its key is edited key by key; a scalar takes
  # the place of the old value on the key's line; any other map or list is written out
  # under the key, which keeps its comment.
  defp replace(name, after_colon, own, indent, old, new) do
    {space, value, comment} = inline(after_colon)

    cond do
      nested?(old, new) and value == "" and Enum.any?(own, &content?/1) ->
        with {:ok, own} <- edit_map(own, indent_of(own, indent + 2), old, new),
             do: {:ok, [name <> after_colon | own]}

      block?(new) ->
        {:ok, [name <> comment | value_lines(new, max(indent_of(own, indent + 2), indent + 2))]}

      true ->
        {:ok, [name <> space <> written(new, value) <> comment]}
    end
  end

  defp nested?(old, new), do: is_map(old) and is_map(new) and block?(old) and block?(new)

  # What is written beneath its key rather than on its line: `{}` and `[]` are scalars.
  defp block?(value), do: (is_map(value) and map_size(value) > 0) or match?([_ | _], value)

  defp value_lines(map, indent) when is_map(map), do: lines(block(map, indent, &plain/1))
  defp value_lines(list, indent), do: lines(Enum.map(list, fn value -> item(value, indent, &plain/1) end))

  defp lines(iodata), do: iodata |> IO.iodata_to_binary() |> String.split("\n") |> Enum.drop(-1)

  # A value that was quoted stays quoted.
  defp written(value, was) when is_binary(value) do
    if String.starts_with?(was, ["\"", "'"]), do: quote_string(value), else: plain(value)
  end

  defp written(value, _was), do: plain(value)

  # What follows a key's colon, as `{space, value, comment}`: the comment keeps the
  # blanks before its `#`, so a value written in the old one's place leaves it where it
  # was. A quoted value may hold a `#`; a bare one ends at the first ` #`.
  defp inline(after_colon) do
    [_all, space, rest] = Regex.run(~r/\A(\s*)(.*)\z/, after_colon)

    cond do
      rest == "" -> {" ", "", ""}
      String.starts_with?(rest, "#") -> {" ", "", space <> rest}
      match = Regex.run(~r/\A("(?:[^"\\]|\\.)*"|'(?:[^']|'')*')(\s*#.*|\s*)\z/, rest) -> value_comment(space, match)
      true -> value_comment(space, Regex.run(~r/\A(.*?)(\s+#.*|)\s*\z/, rest))
    end
  end

  defp value_comment(space, [_all, value, comment]), do: {space, value, comment}

  # Added after the map's last line that holds something, so the comments and blank
  # lines after it stay after it; in a file with none, before its final newline.
  defp add(lines, _indent, []), do: lines

  defp add(lines, indent, added) do
    new = Enum.flat_map(added, fn {key, value} -> lines(entry(key(key), value, indent, &plain/1)) end)

    at =
      case Enum.find_index(Enum.reverse(lines), &content?/1) do
        nil -> if List.last(lines) == "", do: length(lines) - 1, else: length(lines)
        from_end -> length(lines) - from_end
      end

    {above, below} = Enum.split(lines, at)
    above ++ new ++ below
  end

  # The one line at `indent` that is the key, spelled bare or quoted.
  defp locate(lines, indent, key) do
    pattern = key_pattern(indent, key)

    case lines |> Enum.with_index() |> Enum.filter(fn {line, _i} -> line =~ pattern end) do
      [{_line, i}] -> {:ok, i}
      _none_or_twice -> :error
    end
  end

  defp key_pattern(indent, key) do
    key = to_string(key)
    spellings = [key, quote_string(key), "'" <> String.replace(key, "'", "''") <> "'"]
    ~r/\A(#{pad(indent)}(?:#{Enum.map_join(spellings, "|", &Regex.escape/1)})\s*:)((?:\s.*)?)\z/
  end

  # A key's line, the lines beneath it that are its own, and the rest of the map. The
  # comments and blank lines at the end of its own lines belong to whatever follows.
  defp split_key(lines, i, indent) do
    {head, [key_line | rest]} = Enum.split(lines, i)
    {own, tail} = Enum.split_while(rest, &beneath?(&1, indent))
    {trailing, own} = own |> Enum.reverse() |> Enum.split_while(&(not content?(&1)))
    {head, key_line, Enum.reverse(own), Enum.reverse(trailing) ++ tail}
  end

  # Deeper than the key, or a list or a closing bracket at its own indent, which YAML
  # also reads as the key's value.
  defp beneath?(line, indent) do
    not content?(line) or indentation(line) > indent or
      String.starts_with?(line, [pad(indent) <> "- ", pad(indent) <> "]", pad(indent) <> "}"]) or
      line == pad(indent) <> "-"
  end

  defp indent_of(lines, default) do
    case Enum.find(lines, &content?/1) do
      nil -> default
      line -> indentation(line)
    end
  end

  defp indentation(line), do: byte_size(line) - byte_size(String.trim_leading(line, " "))
end
