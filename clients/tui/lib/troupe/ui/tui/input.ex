defmodule Troupe.UI.TUI.Input do
  @moduledoc """
  The text editor behind the command line and a window's input box.

  An input is a `{text, pos}` pair: the string as typed and the cursor as a
  grapheme index into it (`0` before the first grapheme, `String.length(text)`
  after the last). Everything here is pure — the TUI server holds the pair, the
  view asks for the rows it draws as.

  `key/2` owns the motions and deletions a terminal reader is expected to have
  (arrows, word jumps with Alt or Ctrl, Home/End, Delete, Ctrl-W/U/K) and
  returns `:pass` for every other key, so the caller's own bindings — Enter,
  Tab, Esc, a digit that picks an option — keep winning.
  """

  alias ExRatatui.Event.Key
  alias Troupe.UI.TUI.Model

  @cursor "▏"

  @typedoc "The text being edited and the cursor's grapheme index into it."
  @type t :: {String.t(), non_neg_integer()}

  @doc "The cursor marker the box draws; the only glyph the view adds to the text."
  @spec cursor_glyph() :: String.t()
  def cursor_glyph, do: @cursor

  @doc "`pos` brought back inside `text` — anything that replaces the text goes through here."
  @spec clamp(String.t(), integer()) :: non_neg_integer()
  def clamp(text, pos), do: pos |> max(0) |> min(String.length(text))

  @doc "Inserts `str` at the cursor and leaves the cursor after it."
  @spec insert(t(), String.t()) :: t()
  def insert({text, pos}, str) do
    {before_cursor, rest} = split(text, pos)
    {before_cursor <> str <> rest, pos + String.length(str)}
  end

  @doc """
  Applies an editing key, or `:pass` when the key is not one of ours.

  Alt or Ctrl on ←/→ (and on Backspace/Delete) makes the motion a word rather
  than a grapheme, which is what every other terminal input does.
  """
  @spec key(Key.t(), t()) :: {:ok, t()} | :pass
  def key(%Key{code: "left", modifiers: mods}, input),
    do: {:ok, if(word?(mods), do: word_left(input), else: left(input))}

  def key(%Key{code: "right", modifiers: mods}, input),
    do: {:ok, if(word?(mods), do: word_right(input), else: right(input))}

  def key(%Key{code: "up"}, input), do: {:ok, line_step(input, -1)}
  def key(%Key{code: "down"}, input), do: {:ok, line_step(input, 1)}
  def key(%Key{code: "home"}, input), do: {:ok, to_line_start(input)}
  def key(%Key{code: "end"}, input), do: {:ok, to_line_end(input)}
  def key(%Key{code: "a", modifiers: ["ctrl"]}, input), do: {:ok, to_line_start(input)}
  def key(%Key{code: "e", modifiers: ["ctrl"]}, input), do: {:ok, to_line_end(input)}

  def key(%Key{code: "backspace", modifiers: mods}, input),
    do: {:ok, if(word?(mods), do: cut(input, word_left(input)), else: cut(input, left(input)))}

  def key(%Key{code: "w", modifiers: ["ctrl"]}, input), do: {:ok, cut(input, word_left(input))}

  def key(%Key{code: "delete", modifiers: mods}, input),
    do: {:ok, if(word?(mods), do: cut(input, word_right(input)), else: cut(input, right(input)))}

  def key(%Key{code: "u", modifiers: ["ctrl"]}, input), do: {:ok, cut(input, to_line_start(input))}
  def key(%Key{code: "k", modifiers: ["ctrl"]}, input), do: {:ok, cut(input, to_line_end(input))}
  def key(%Key{}, _input), do: :pass

  @doc """
  The wrapped rows the box draws — the text with the cursor marker spliced in at
  `pos` — and the index of the row the cursor landed on, so the caller can pick
  the window of rows that keeps it on screen.
  """
  @spec rows(t(), pos_integer()) :: {[String.t()], non_neg_integer()}
  def rows({text, pos}, width) do
    {before_cursor, rest} = split(text, pos)

    {wrap(before_cursor <> @cursor <> rest, width),
     length(wrap(before_cursor <> @cursor, width)) - 1}
  end

  @doc "Every wrapped row `text` takes at `width`, newlines included."
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width),
    do: text |> String.split("\n") |> Enum.flat_map(&Model.wrap(&1, width, :char))

  ## Motions

  defp left({text, pos}), do: {text, max(pos - 1, 0)}
  defp right({text, pos}), do: {text, clamp(text, pos + 1)}

  # A word jump skips whatever separates words, then the word itself — so it
  # lands on a word's first grapheme going left and past its last going right.
  defp word_left({text, pos}) do
    graphemes = text |> String.graphemes() |> Enum.take(pos) |> Enum.reverse()
    {text, pos - skipped(graphemes)}
  end

  defp word_right({text, pos}) do
    graphemes = text |> String.graphemes() |> Enum.drop(pos)
    {text, pos + skipped(graphemes)}
  end

  defp skipped(graphemes) do
    {separators, rest} = Enum.split_while(graphemes, &(not word_char?(&1)))
    length(separators) + length(Enum.take_while(rest, &word_char?/1))
  end

  defp word_char?(g), do: Regex.match?(~r/^[\p{L}\p{N}_]$/u, g)

  # The column, as text: what the cursor has of its own line to its left.
  defp to_line_start({text, pos}) do
    column = text |> split(pos) |> elem(0) |> String.split("\n") |> List.last()
    {text, pos - String.length(column)}
  end

  defp to_line_end({text, pos}) do
    rest = text |> split(pos) |> elem(1)
    {text, pos + String.length(hd(String.split(rest, "\n")))}
  end

  # ↑/↓ move between the text's own lines, keeping the column where it can; at
  # the first or last line they go to that line's start or end instead.
  defp line_step({text, pos} = input, step) do
    prefix_lines = text |> split(pos) |> elem(0) |> String.split("\n")
    {row, column} = {length(prefix_lines) - 1, String.length(List.last(prefix_lines))}
    lines = String.split(text, "\n")
    target = row + step

    if target < 0 or target >= length(lines) do
      if step < 0, do: to_line_start(input), else: to_line_end(input)
    else
      start = lines |> Enum.take(target) |> Enum.map(&(String.length(&1) + 1)) |> Enum.sum()
      {text, start + min(column, String.length(Enum.at(lines, target)))}
    end
  end

  # A deletion is the text between where the cursor is and where a motion would
  # have put it, taken away; the cursor ends at the lower of the two.
  defp cut({text, pos}, {_text, target}) do
    {from, to} = {min(pos, target), max(pos, target)}
    graphemes = String.graphemes(text)
    {kept, rest} = Enum.split(graphemes, from)
    {Enum.join(kept) <> Enum.join(Enum.drop(rest, to - from)), from}
  end

  defp word?(mods), do: "alt" in mods or "ctrl" in mods

  defp split(text, pos) do
    {before_cursor, rest} = text |> String.graphemes() |> Enum.split(pos)
    {Enum.join(before_cursor), Enum.join(rest)}
  end
end
