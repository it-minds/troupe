defmodule Troupe.Tool.Bound do
  @moduledoc """
  Pure bounding of tool output, applied when a result is created and before it
  is appended to the conversation. Nothing already in history is ever shrunk:
  rewriting an earlier message would invalidate the provider's prompt cache from
  that point on (Decision 85).

  Every function returns `{text, omission | nil}`. The caller turns an omission
  into a marker with `marker/2`, supplying the exact call that retrieves what was
  cut — a bounded result always says how to get the rest.

  `sanitize/1` runs first everywhere: ANSI escapes go, invalid UTF-8 becomes
  U+FFFD. Both matter for `Jason.encode!/1`, which raises on invalid UTF-8, and
  every cut here is on a line or grapheme boundary for the same reason.
  """

  @type unit :: :lines | :items | :characters | :elements

  @type omission :: %{
          first: pos_integer(),
          last: pos_integer(),
          total: pos_integer(),
          unit: unit()
        }

  @type result :: {String.t(), omission() | nil}

  # CSI/OSC and the single-character escapes a terminal-bound tool emits.
  @ansi ~r/\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\)|[@-Z\\-_])/

  @doc """
  Strips ANSI escapes and replaces invalid UTF-8. Raw process output and binary
  files reach us as arbitrary bytes; `Jason` raises on those, and a tool result
  that cannot be encoded takes the whole turn down.
  """
  @spec sanitize(binary()) :: String.t()
  def sanitize(text) when is_binary(text) do
    text
    |> scrub()
    |> then(&Regex.replace(@ansi, &1, ""))
    |> String.replace("\r\n", "\n")
  end

  defp scrub(text) do
    case String.valid?(text) do
      true -> text
      false -> do_scrub(text, [])
    end
  end

  defp do_scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_scrub(<<c::utf8, rest::binary>>, acc), do: do_scrub(rest, [<<c::utf8>> | acc])

  defp do_scrub(<<_, rest::binary>>, acc), do: do_scrub(rest, ["�" | acc])

  @doc """
  Log-like output: keeps `head` lines from the front and `tail` from the back,
  because a command's errors, stack traces and failure summary come last.
  """
  @spec head_tail(String.t(), pos_integer(), pos_integer()) :: result()
  def head_tail(text, head, tail) when head > 0 and tail > 0 do
    lines = String.split(text, "\n")
    total = length(lines)

    if total <= head + tail do
      {text, nil}
    else
      kept = Enum.take(lines, head) ++ ["￿"] ++ Enum.take(lines, -tail)

      {Enum.join(kept, "\n"), %{first: head + 1, last: total - tail, total: total, unit: :lines}}
    end
  end

  @doc """
  A line window over a document, 1-based and inclusive. Reports the omission
  against the file's own total so the caller can point at the next offset.
  """
  @spec window(String.t(), pos_integer(), pos_integer()) :: result()
  def window(text, offset, limit) when offset > 0 and limit > 0 do
    lines = String.split(text, "\n")
    total = length(lines)
    shown = lines |> Enum.drop(offset - 1) |> Enum.take(limit)
    last = min(offset + limit - 1, total)

    if last >= total do
      {Enum.join(shown, "\n"), nil}
    else
      {Enum.join(shown, "\n"), %{first: last + 1, last: total, total: total, unit: :lines}}
    end
  end

  @doc "Caps a list of items (matches, paths) and reports the total."
  @spec items([String.t()], pos_integer(), pos_integer()) :: result()
  def items(list, offset, max) when offset > 0 and max > 0 do
    total = length(list)
    shown = list |> Enum.drop(offset - 1) |> Enum.take(max)
    last = min(offset + max - 1, total)

    if last >= total do
      {Enum.join(shown, "\n"), nil}
    else
      {Enum.join(shown, "\n"), %{first: last + 1, last: total, total: total, unit: :items}}
    end
  end

  @doc """
  Trims the top-level arrays of a JSON document to their first `max` elements,
  each followed by a count of the rest, rather than cutting through the middle
  of the structure. Anything that does not parse falls through to `chars/2`.
  """
  @spec json(String.t(), pos_integer(), pos_integer()) :: result()
  def json(text, max, max_chars) do
    case Jason.decode(text) do
      {:ok, decoded} ->
        case trim(decoded, max, 0) do
          {_trimmed, 0} ->
            chars(text, max_chars)

          {trimmed, dropped} ->
            {capped, _} = trimmed |> Jason.encode!(pretty: true) |> chars(max_chars)

            {capped, %{first: max + 1, last: max + dropped, total: max + dropped, unit: :elements}}
        end

      {:error, _} ->
        chars(text, max_chars)
    end
  end

  defp trim(list, max, dropped) when is_list(list) do
    rest = max(length(list) - max, 0)
    {Enum.take(list, max), dropped + rest}
  end

  defp trim(map, max, dropped) when is_map(map) do
    Enum.reduce(map, {%{}, dropped}, fn {k, v}, {acc, d} ->
      {v, d} = trim(v, max, d)
      {Map.put(acc, k, v), d}
    end)
  end

  defp trim(other, _max, dropped), do: {other, dropped}

  @doc """
  The backstop: a hard character cap for output with no line structure at all —
  a minified file on one line, a base64 blob. Cuts on a grapheme boundary, never
  with `binary_part/3`, so the result stays valid UTF-8.
  """
  @spec chars(String.t(), pos_integer()) :: result()
  def chars(text, max) when max > 0 do
    total = String.length(text)

    if total <= max do
      {text, nil}
    else
      {String.slice(text, 0, max), %{first: max + 1, last: total, total: total, unit: :characters}}
    end
  end

  @doc """
  Renders an omission as the marker that goes into the result, stating what was
  left out and the exact call that returns it.
  """
  @spec marker(omission(), String.t()) :: String.t()
  def marker(%{first: first, last: last, total: total, unit: unit}, retrieval) do
    "[… #{unit} #{first}–#{last} of #{total} omitted. #{retrieval}]"
  end

  @doc """
  Puts a marker where `head_tail/3` cut, or appends it for a cut at the end.
  The placeholder is a character no tool output contains.
  """
  @spec place(String.t(), omission(), String.t()) :: String.t()
  def place(text, omission, retrieval) do
    marker = marker(omission, retrieval)

    if String.contains?(text, "￿"),
      do: String.replace(text, "￿", marker),
      else: text <> "\n" <> marker
  end

  @doc "`{text, nil}` passes through; anything cut gets its marker."
  @spec render(result(), (omission() -> String.t())) :: String.t()
  def render({text, nil}, _retrieval), do: text
  def render({text, omission}, retrieval), do: place(text, omission, retrieval.(omission))
end
