defmodule Troupe.Config.TOML do
  @moduledoc """
  A TOML document read into maps, for the one file Troupe reads that is written in it:
  Codex's `config.toml`, whose `[mcp_servers.*]` tables an import copies (Decision 825).

  Narrow on purpose, and written here rather than taken as a dependency: tables and
  arrays of tables, bare, quoted and dotted keys, the four kinds of string, integers,
  floats, booleans, arrays and inline tables, as TOML 1.0 has them, which is everything a
  Codex file holds. A date or a time is kept as its text, and `inf` and `nan` as theirs,
  since nothing an import reads is one. It is a reader, not a validator: a key given twice
  is the later one, where the specification refuses the file, because the tool that owns
  the file has refused it already. Anything it cannot read is an error naming the line.
  """

  @doc "Read a document: `{:ok, map}`, or `{:error, \"line N: why\"}`."
  @spec decode(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    text = String.replace_prefix(text, "﻿", "")

    try do
      {:ok, document(text, %{}, [])}
    catch
      {:toml, rest, why} -> {:error, "line #{line(text, rest)}: #{why}"}
    end
  end

  # -- the document ------------------------------------------------------------------

  defp document(text, root, path) do
    case skip_blank(text) do
      "" ->
        root

      "[[" <> rest ->
        {keys, rest} = keys(rest)
        rest = rest |> skip_ws() |> expect("]]")
        document(end_of_line(rest), append_table(root, keys, rest), keys)

      "[" <> rest ->
        {keys, rest} = keys(rest)
        rest = rest |> skip_ws() |> expect("]")
        document(end_of_line(rest), update_at(root, keys, & &1, rest), keys)

      line ->
        {keys, value, rest} = pair(line)
        document(end_of_line(rest), put(root, path ++ keys, value, rest), path)
    end
  end

  defp pair(text) do
    {keys, rest} = keys(text)
    {value, rest} = rest |> skip_ws() |> expect("=") |> skip_ws() |> value()
    {keys, value, rest}
  end

  defp keys(text) do
    {key, rest} = text |> skip_ws() |> key()

    case skip_ws(rest) do
      "." <> more ->
        {keys, rest} = keys(more)
        {[key | keys], rest}

      _other ->
        {[key], rest}
    end
  end

  defp key("\"" <> rest), do: basic(rest, [])
  defp key("'" <> rest), do: literal(rest)

  defp key(text) do
    case Regex.run(~r/^[A-Za-z0-9_-]+/, text) do
      [bare] -> {bare, drop(text, bare)}
      nil -> fail(text, "expected a key")
    end
  end

  defp expect(text, token) do
    if String.starts_with?(text, token),
      do: drop(text, token),
      else: fail(text, "expected #{token}")
  end

  defp end_of_line(text) do
    case skip_ws(text) do
      "" -> ""
      "\r\n" <> rest -> rest
      "\n" <> rest -> rest
      "#" <> _ = comment -> skip_comment(comment)
      other -> fail(other, "expected the end of the line")
    end
  end

  # -- values ------------------------------------------------------------------------

  defp value("\"\"\"" <> rest), do: rest |> trim_newline() |> multiline_basic([])
  defp value("'''" <> rest), do: rest |> trim_newline() |> multiline_literal()
  defp value("\"" <> rest), do: basic(rest, [])
  defp value("'" <> rest), do: literal(rest)
  defp value("[" <> rest), do: rest |> skip_blank() |> array([])
  defp value("{" <> rest), do: rest |> skip_blank() |> inline_table(%{})
  defp value(text), do: scalar(text)

  defp array("]" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp array(text, acc) do
    {value, rest} = value(text)

    case skip_blank(rest) do
      "," <> rest -> rest |> skip_blank() |> array([value | acc])
      "]" <> rest -> {Enum.reverse([value | acc]), rest}
      other -> fail(other, "expected , or ] in an array")
    end
  end

  defp inline_table("}" <> rest, acc), do: {acc, rest}

  defp inline_table(text, acc) do
    {keys, value, rest} = pair(text)
    acc = put(acc, keys, value, rest)

    case skip_blank(rest) do
      "," <> rest -> rest |> skip_blank() |> inline_table(acc)
      "}" <> rest -> {acc, rest}
      other -> fail(other, "expected , or } in an inline table")
    end
  end

  # A number, a boolean, a date or a time: a run up to whatever ends a value, a local
  # date-time's space between its date and its time included.
  defp scalar(text) do
    case Regex.run(~r/^[^\s,\]}#]+/, text) do
      [token] ->
        {token, rest} = with_time(token, drop(text, token))
        {token(token, text), rest}

      nil ->
        fail(text, "expected a value")
    end
  end

  defp with_time(token, rest) do
    with true <- token =~ ~r/^\d{4}-\d{2}-\d{2}$/,
         [time] <- Regex.run(~r/^ \d{2}:[^\s,\]}#]+/, rest) do
      {token <> time, drop(rest, time)}
    else
      _ -> {token, rest}
    end
  end

  defp token("true", _at), do: true
  defp token("false", _at), do: false

  defp token(token, at) do
    digits = String.replace(token, "_", "")

    cond do
      token =~ ~r/^[+-]?(0|[1-9](_?\d)*)$/ ->
        String.to_integer(digits)

      token =~ ~r/^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$/ ->
        digits |> drop("0x") |> String.to_integer(16)

      token =~ ~r/^0o[0-7](_?[0-7])*$/ ->
        digits |> drop("0o") |> String.to_integer(8)

      token =~ ~r/^0b[01](_?[01])*$/ ->
        digits |> drop("0b") |> String.to_integer(2)

      token =~ ~r/^[+-]?(0|[1-9](_?\d)*)(\.\d(_?\d)*)?([eE][+-]?\d(_?\d)*)?$/ ->
        float(digits)

      token =~ ~r/^[+-]?(inf|nan)$/ ->
        token

      token =~ ~r/^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}:\d{2}/ ->
        token

      true ->
        fail(at, "#{token} is not a value TOML has")
    end
  end

  # `1e5` and `1.5`: Elixir reads a float with a fraction, so one without gets `.0`.
  defp float(digits) do
    digits
    |> String.replace(~r/^([+-]?\d+)([eE])/, "\\1.0\\2")
    |> String.to_float()
  end

  # -- strings -----------------------------------------------------------------------

  defp basic("\"" <> rest, acc), do: {done(acc), rest}

  defp basic("\\" <> rest, acc) do
    {char, rest} = escape(rest)
    basic(rest, [char | acc])
  end

  defp basic(<<c, _::binary>> = at, _acc) when c in [?\n, ?\r],
    do: fail(at, "a string is not closed on its line")

  defp basic("", _acc), do: fail("", "a string is not closed")
  defp basic(<<c::utf8, rest::binary>>, acc), do: basic(rest, [<<c::utf8>> | acc])
  defp basic(at, _acc), do: fail(at, "the text is not UTF-8")

  defp literal(text) do
    case :binary.split(text, "'") do
      [content, rest] ->
        if String.contains?(content, "\n"),
          do: fail(text, "a string is not closed on its line"),
          else: {content, rest}

      [_unclosed] ->
        fail(text, "a string is not closed")
    end
  end

  # Up to two quotes before the closing three belong to the string.
  defp multiline_basic("\"\"\"" <> rest, acc) do
    case rest do
      "\"\"" <> rest -> {done(acc) <> "\"\"", rest}
      "\"" <> rest -> {done(acc) <> "\"", rest}
      rest -> {done(acc), rest}
    end
  end

  defp multiline_basic("\\" <> rest, acc) do
    # A backslash ending a line takes the line break and the blanks after it away.
    case skip_ws(rest) do
      <<c, _::binary>> = break when c in [?\n, ?\r] ->
        break |> skip_space() |> multiline_basic(acc)

      _escape ->
        {char, rest} = escape(rest)
        multiline_basic(rest, [char | acc])
    end
  end

  defp multiline_basic("", _acc), do: fail("", "a \"\"\" string is not closed")

  defp multiline_basic(<<c::utf8, rest::binary>>, acc),
    do: multiline_basic(rest, [<<c::utf8>> | acc])

  defp multiline_basic(at, _acc), do: fail(at, "the text is not UTF-8")

  defp multiline_literal(text) do
    case :binary.split(text, "'''") do
      [content, "''" <> rest] -> {content <> "''", rest}
      [content, "'" <> rest] -> {content <> "'", rest}
      [content, rest] -> {content, rest}
      [_unclosed] -> fail(text, "a ''' string is not closed")
    end
  end

  defp escape("b" <> rest), do: {"\b", rest}
  defp escape("t" <> rest), do: {"\t", rest}
  defp escape("n" <> rest), do: {"\n", rest}
  defp escape("f" <> rest), do: {"\f", rest}
  defp escape("r" <> rest), do: {"\r", rest}
  defp escape("e" <> rest), do: {"\e", rest}
  defp escape("\"" <> rest), do: {"\"", rest}
  defp escape("\\" <> rest), do: {"\\", rest}
  defp escape(<<"u", hex::binary-size(4), rest::binary>> = at), do: {codepoint(hex, at), rest}
  defp escape(<<"U", hex::binary-size(8), rest::binary>> = at), do: {codepoint(hex, at), rest}
  defp escape(at), do: fail(at, "an escape TOML does not have")

  defp codepoint(hex, at) do
    with true <- hex =~ ~r/^[0-9A-Fa-f]+$/,
         code = String.to_integer(hex, 16),
         true <- code < 0xD800 or code in 0xE000..0x10FFFF do
      <<code::utf8>>
    else
      _ -> fail(at, "\\u#{hex} is not a character")
    end
  end

  defp done(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp trim_newline("\r\n" <> rest), do: rest
  defp trim_newline("\n" <> rest), do: rest
  defp trim_newline(text), do: text

  # -- tables ------------------------------------------------------------------------

  defp put(map, keys, value, at) do
    {path, [last]} = Enum.split(keys, -1)
    update_at(map, path, &Map.put(&1, last, value), at)
  end

  # `[[a.b]]`: one more table at the end of the list `a.b` names.
  defp append_table(root, keys, at) do
    {path, [last]} = Enum.split(keys, -1)

    update_at(
      root,
      path,
      fn table ->
        case Map.get(table, last, []) do
          list when is_list(list) -> Map.put(table, last, list ++ [%{}])
          _other -> fail(at, "#{last} is a value, not a list of tables")
        end
      end,
      at
    )
  end

  # The table a path names, made where it is not there yet; through a list of tables, the
  # last of them, which is the one `[[…]]` opened last.
  defp update_at(table, [], fun, _at), do: fun.(table)

  defp update_at(table, [key | rest], fun, at) do
    case Map.get(table, key, %{}) do
      %{} = child ->
        Map.put(table, key, update_at(child, rest, fun, at))

      [_ | _] = list ->
        if is_map(List.last(list)),
          do: Map.put(table, key, List.update_at(list, -1, &update_at(&1, rest, fun, at))),
          else: fail(at, "#{key} is a value, not a table")

      _value ->
        fail(at, "#{key} is a value, not a table")
    end
  end

  # -- blanks ------------------------------------------------------------------------

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_ws(rest)
  defp skip_ws(text), do: text

  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: skip_space(rest)
  defp skip_space(text), do: text

  defp skip_blank(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: skip_blank(rest)
  defp skip_blank("#" <> _ = comment), do: comment |> skip_comment() |> skip_blank()
  defp skip_blank(text), do: text

  defp skip_comment(text) do
    case :binary.split(text, "\n") do
      [_comment, rest] -> rest
      [_comment] -> ""
    end
  end

  defp drop(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  defp fail(at, why), do: throw({:toml, at, why})

  defp line(text, rest) do
    seen = binary_part(text, 0, max(byte_size(text) - byte_size(rest), 0))
    length(:binary.matches(seen, "\n")) + 1
  end
end
