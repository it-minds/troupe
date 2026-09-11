defmodule Troupe.Tool.Diff do
  @moduledoc "Minimal unified-style line diff for approval previews and window output."

  @spec unified(String.t(), String.t(), String.t()) :: String.t()
  def unified(path, old, new) do
    old_lines = String.split(old, ~r/\r?\n/)
    new_lines = String.split(new, ~r/\r?\n/)

    body =
      List.myers_difference(old_lines, new_lines)
      |> Enum.flat_map(fn
        {:eq, lines} -> context(lines)
        {:del, lines} -> Enum.map(lines, &("-" <> &1))
        {:ins, lines} -> Enum.map(lines, &("+" <> &1))
      end)
      |> Enum.join("\n")

    "--- #{path}\n+++ #{path}\n#{body}"
  end

  defp context(lines) when length(lines) <= 6, do: Enum.map(lines, &(" " <> &1))

  defp context(lines) do
    Enum.map(Enum.take(lines, 3), &(" " <> &1)) ++
      ["@@ #{length(lines) - 6} unchanged lines @@"] ++
      Enum.map(Enum.take(lines, -3), &(" " <> &1))
  end

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
