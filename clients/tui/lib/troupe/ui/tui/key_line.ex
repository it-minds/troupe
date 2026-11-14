defmodule Troupe.UI.TUI.KeyLine do
  @moduledoc """
  A page's key line, fitted to the width it is drawn at.

  A page says its keys on the command box's top border, as one line: ` label — key · key ·
  Esc back `. A terminal narrower than the line cut its end, and the end is where the way
  out is. `fit/2` keeps the line whole where it fits; where it does not, the label goes
  first, then the keys from the end of the line, the least important, and never the way out
  (`Esc …`) or what acts (`Enter …`) while a narrower line still has room for them. Below
  that only the way out stays. What leaves the line is returned beside it, in the line's
  order, for the box under the line to show: nothing a page offers is lost to the width.
  """

  @separator " · "

  @doc """
  The line as it fits `width` columns, and the keys that left it (`nil` when none did).

      iex> Troupe.UI.TUI.KeyLine.fit(" memory — ↑↓ · a add · Esc back ", 80)
      {" memory — ↑↓ · a add · Esc back ", nil}

      iex> Troupe.UI.TUI.KeyLine.fit(" memory — ↑↓ · a add · Esc back ", 20)
      {" ↑↓ · Esc back ", "a add"}
  """
  @spec fit(String.t(), pos_integer()) :: {String.t(), String.t() | nil}
  def fit(line, width) do
    if String.length(line) <= width do
      {line, nil}
    else
      {label, keys} = parse(line)
      drop(label, Enum.with_index(keys), [], width)
    end
  end

  defp parse(line) do
    body = String.trim(line)

    case String.split(body, " — ", parts: 2) do
      [label, rest] -> {label, String.split(rest, @separator)}
      [rest] -> {nil, String.split(rest, @separator)}
    end
  end

  # The label first, then a key the line can spare from its end, then what acts; the way
  # out never, nor the one key a line is left with: the border cuts that, as it did.
  defp drop(label, keys, gone, width) do
    if fits?(label, keys, width) or (label == nil and length(keys) == 1) do
      done(label, keys, gone)
    else
      cond do
        label != nil -> drop(nil, keys, gone, width)
        victim = last(keys, &spare?/1) -> drop(nil, keys -- [victim], [victim | gone], width)
        victim = last(keys, &(not out?(&1))) -> drop(nil, keys -- [victim], [victim | gone], width)
        true -> done(nil, keys, gone)
      end
    end
  end

  defp last(keys, keep?), do: keys |> Enum.reverse() |> Enum.find(fn {key, _i} -> keep?.(key) end)

  defp spare?(key), do: not out?(key) and not acts?(key)
  defp out?(key), do: String.starts_with?(key, "Esc")
  defp acts?(key), do: String.starts_with?(key, "Enter")

  defp fits?(label, keys, width), do: String.length(render(label, keys)) <= width

  defp done(label, keys, []), do: {render(label, keys), nil}

  defp done(label, keys, gone) do
    more = gone |> Enum.sort_by(&elem(&1, 1)) |> Enum.map_join(@separator, &elem(&1, 0))
    {render(label, keys), more}
  end

  defp render(label, keys) do
    words = Enum.map_join(keys, @separator, &elem(&1, 0))
    if label, do: " #{label} — #{words} ", else: " #{words} "
  end
end
