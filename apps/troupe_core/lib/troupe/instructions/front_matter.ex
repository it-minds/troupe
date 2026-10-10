defmodule Troupe.Instructions.FrontMatter do
  @moduledoc """
  A rule's front matter, read as Decision 809 reads a Cursor rule's: a line per key, as
  Cursor writes it and YAML would not always read it (`globs: *.ts` is an alias to YAML).
  The one reader for the loader's `.troupe/rules/*.md` (Decision 828) and for onboarding's
  Cursor and Copilot rules and opencode's instruction files (Decision 827), so a rule
  onboarding read one way is never read another once it is written.

  - `split/1`: the keys, each with its lines (the line after `key:` and the indented or
    `-` lines under it, trimmed), and the body after the closing `---`, trimmed. A text
    without front matter, or with one that is never closed, has no keys and is all body.
  - `rule/1`: when the rule applies, as 809 reads it. `alwaysApply` is true when it says
    `true`; `description` is folded across its lines (`|` and `>` too); `globs` is a
    comma-separated string (commas inside `{}` kept), a `[...]` list, or `-` lines, each
    with its quotes taken off, and one quoted string is unquoted before it is split, as
    Copilot writes `applyTo: "**/*.ts,**/*.tsx"`.

  Pure.
  """

  @typedoc "The front matter's keys, each with its lines as written, trimmed."
  @type fields :: %{optional(String.t()) => [String.t()]}

  @typedoc "When a rule applies, as its front matter says."
  @type rule :: %{always: boolean(), globs: [String.t()], description: String.t() | nil}

  @doc """
  The front matter's keys and the body, trimmed. Windows line endings and a byte-order
  mark are taken off first.
  """
  @spec split(String.t()) :: {fields(), String.t()}
  def split(text) do
    text = text |> String.replace("\r\n", "\n") |> String.trim_leading("\uFEFF")
    [first | rest] = String.split(text, "\n")

    with "---" <- String.trim(first),
         {front, [_close | body]} <- Enum.split_while(rest, &(String.trim(&1) != "---")) do
      {keys(front), body |> Enum.join("\n") |> String.trim()}
    else
      _no_front_matter -> {%{}, String.trim(text)}
    end
  end

  @doc "`alwaysApply`, `globs` and `description`, as Decision 809 reads them."
  @spec rule(fields()) :: rule()
  def rule(fields) do
    %{
      always: String.downcase(scalar(fields["alwaysApply"])) == "true",
      globs: globs(fields["globs"]),
      description: description(fields)
    }
  end

  @doc "A `description`, folded to one line, or `nil` when there is none."
  @spec description(fields()) :: String.t() | nil
  def description(fields) do
    case scalar(fields["description"]) do
      "" -> nil
      description -> description
    end
  end

  @doc "A key's lines as globs: a comma-separated string, a `[...]` list or `-` lines."
  @spec globs([String.t()] | nil) :: [String.t()]
  def globs(nil), do: []

  def globs(["" | lines]) do
    for "-" <> item <- lines, item = unquote_value(item), item != "", do: item
  end

  def globs(lines) do
    value = lines |> Enum.join(" ") |> String.trim() |> unquote_whole()

    value =
      if String.starts_with?(value, "[") and String.ends_with?(value, "]"),
        do: String.slice(value, 1..-2//1),
        else: value

    for item <- split_globs(value), item = unquote_value(item), item != "", do: item
  end

  # Each `key:` line and the lines after it that are indented or a list's `-`, trimmed.
  defp keys(lines) do
    lines
    |> Enum.reduce({%{}, nil}, fn line, {fields, key} ->
      case Regex.run(~r/^([A-Za-z][\w-]*)\s*:\s*(.*)$/, line) do
        [_line, name, value] -> {Map.put(fields, name, [String.trim(value)]), name}
        nil when key != nil -> {continue(fields, key, line), key}
        nil -> {fields, nil}
      end
    end)
    |> elem(0)
  end

  defp continue(fields, key, line) do
    if line =~ ~r/^(\s+\S|-)/,
      do: Map.update!(fields, key, &(&1 ++ [String.trim(line)])),
      else: fields
  end

  defp scalar(nil), do: ""

  defp scalar([block | lines]) when block in ["|", ">", "|-", ">-"],
    do: lines |> Enum.join(" ") |> unquote_value()

  defp scalar(lines), do: lines |> Enum.join(" ") |> unquote_value()

  # One quoted string, its quotes off, so the commas inside it split it; `"a", "b"` is two
  # quoted items, each of which loses its own.
  defp unquote_whole(<<q, rest::binary>> = value) when q in [?", ?'] do
    case String.split(rest, <<q>>) do
      [inner, ""] -> inner
      _more -> value
    end
  end

  defp unquote_whole(value), do: value

  # On the commas outside braces, so `**/*.{ts,tsx}` stays one glob.
  defp split_globs(value) do
    {items, current, _depth} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {items, current, 0} -> {[current | items], "", 0}
        "{", {items, current, depth} -> {items, current <> "{", depth + 1}
        "}", {items, current, depth} -> {items, current <> "}", max(depth - 1, 0)}
        char, {items, current, depth} -> {items, current <> char, depth}
      end)

    Enum.reverse([current | items])
  end

  defp unquote_value(value) do
    value = String.trim(value)

    case value do
      <<q, rest::binary>> when q in [?", ?'] and byte_size(rest) > 0 ->
        if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: value

      _other ->
        value
    end
  end
end
