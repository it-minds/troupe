defmodule Troupe.Tool.Diff do
  @moduledoc "Minimal unified-style line diff for approval previews and window output."

  @spec unified(String.t(), String.t(), String.t()) :: String.t()
  def unified(path, old, new) do
    old_lines = String.split(old, ~r/\r?\n/)
    new_lines = String.split(new, ~r/\r?\n/)
    ops = List.myers_difference(old_lines, new_lines)
    last = length(ops) - 1

    body =
      ops
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:eq, lines}, i} -> context(lines, i == 0, i == last)
        {{:del, lines}, _} -> Enum.map(lines, &("-" <> &1))
        {{:ins, lines}, _} -> Enum.map(lines, &("+" <> &1))
      end)
      |> Enum.join("\n")

    "--- #{path}\n+++ #{path}\n#{body}"
  end

  # Context around a change: the lines just before it and just after it. An unchanged run
  # at the top of the file has nothing before it worth showing, one at the bottom nothing
  # after it — printing those only pushes the change off the reader's screen.
  defp context(lines, _first?, _last?) when length(lines) <= 6,
    do: Enum.map(lines, &(" " <> &1))

  defp context(lines, true, true), do: [omitted(length(lines))]

  defp context(lines, true, false),
    do: [omitted(length(lines) - 3)] ++ Enum.map(Enum.take(lines, -3), &(" " <> &1))

  defp context(lines, false, true),
    do: Enum.map(Enum.take(lines, 3), &(" " <> &1)) ++ [omitted(length(lines) - 3)]

  defp context(lines, false, false) do
    Enum.map(Enum.take(lines, 3), &(" " <> &1)) ++
      [omitted(length(lines) - 6)] ++
      Enum.map(Enum.take(lines, -3), &(" " <> &1))
  end

  defp omitted(n), do: "@@ #{n} unchanged lines @@"

  @spec stat(String.t(), String.t()) :: String.t()
  def stat(old, new) do
    diff = List.myers_difference(String.split(old, ~r/\r?\n/), String.split(new, ~r/\r?\n/))

    ins =
      diff
      |> Enum.filter(&match?({:ins, _}, &1))
      |> Enum.map(fn {_, l} -> length(l) end)
      |> Enum.sum()

    del =
      diff
      |> Enum.filter(&match?({:del, _}, &1))
      |> Enum.map(fn {_, l} -> length(l) end)
      |> Enum.sum()

    "+#{ins} -#{del}"
  end
end
