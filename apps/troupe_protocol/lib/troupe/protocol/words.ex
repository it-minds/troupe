defmodule Troupe.Protocol.Words do
  @moduledoc """
  Durations, counts and lists as a person reads them.

  The daemon, the plane, the gateway and the terminal all write sentences with a
  duration, a count or a list in them, and a person reads them side by side. They are
  written here, in the one app every other app and the TUI may call, so a minute is
  spelled one way wherever it appears.
  """

  @doc """
  A duration in milliseconds, in words: `0 s`, `1.5 s`, `59 s`, `1 min`, `1 min 30 s`,
  `1 h 1 min`.

  Under a minute the seconds keep one decimal place, dropped when it is `0`; from a
  minute up the whole seconds are split into hours, minutes and seconds, and a part that
  is `0` is left out.

  `:short` is the terminal's compact form, for a strip or a header: `0s`, `14s`, `1m`,
  `4m 2s`, `1h 1m`, whole seconds always.

  `:adjective` is a limit's size before its noun, as the stop sentence says it ("its
  30-minute working limit"): `45-second`, `30-minute`, `90-minute`, `2-hour`; hours only
  when they are whole, minutes and seconds rounded.
  """
  @spec duration(number(), :words | :short | :adjective) :: String.t()
  def duration(ms, style \\ :words)

  def duration(ms, style) when is_float(ms), do: duration(trunc(ms), style)
  def duration(ms, style) when ms < 0, do: duration(0, style)

  def duration(ms, :adjective) when ms >= 3_600_000 and rem(ms, 3_600_000) == 0,
    do: "#{div(ms, 3_600_000)}-hour"

  def duration(ms, :adjective) when ms >= 60_000, do: "#{round(ms / 60_000)}-minute"
  def duration(ms, :adjective), do: "#{round(ms / 1000)}-second"

  def duration(ms, :words) when ms < 59_950, do: tenths(round(ms / 100)) <> " s"
  def duration(ms, :words), do: ms |> div(1000) |> max(60) |> parts(["h", "min", "s"], " ")
  def duration(ms, :short), do: ms |> div(1000) |> parts(["h", "m", "s"], "")

  defp tenths(n) when rem(n, 10) == 0, do: Integer.to_string(div(n, 10))
  defp tenths(n), do: "#{div(n, 10)}.#{rem(n, 10)}"

  defp parts(0, [_h, _m, s], gap), do: "0" <> gap <> s

  defp parts(seconds, units, gap) do
    [div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)]
    |> Enum.zip(units)
    |> Enum.reject(fn {n, _unit} -> n == 0 end)
    |> Enum.map_join(" ", fn {n, unit} -> "#{n}#{gap}#{unit}" end)
  end

  @doc """
  How long ago `then` was at `now`, as a person says it: `just now`, `3 min ago`,
  `2 h ago`, `yesterday`, `4 days ago`, and the date (`2026-10-01`) from thirty days on.
  """
  @spec ago(DateTime.t(), DateTime.t()) :: String.t()
  def ago(%DateTime{} = then, %DateTime{} = now \\ DateTime.utc_now()) do
    case DateTime.diff(now, then) do
      s when s < 60 -> "just now"
      s when s < 3600 -> "#{div(s, 60)} min ago"
      s when s < 86_400 -> "#{div(s, 3600)} h ago"
      s when s < 2 * 86_400 -> "yesterday"
      s when s < 30 * 86_400 -> "#{div(s, 86_400)} days ago"
      _s -> then |> DateTime.to_date() |> Date.to_iso8601()
    end
  end

  @doc """
  A count and its noun: `0 files`, `1 file`, `2 files`. A noun whose plural is not its
  singular with an `s` gives both: `count(2, "entry", "entries")`.
  """
  @spec count(integer(), String.t(), String.t()) :: String.t()
  def count(n, one, many \\ nil), do: "#{n} #{plural(n, one, many)}"

  @doc """
  The noun alone, as the count `n` takes it: `plural(1, "file")` is `file`,
  `plural(2, "file")` is `files`, `plural(2, "entry", "entries")` is `entries`.
  """
  @spec plural(integer(), String.t(), String.t() | nil) :: String.t()
  def plural(n, one, many \\ nil)
  def plural(1, one, _many), do: one
  def plural(_n, one, nil), do: one <> "s"
  def plural(_n, _one, many), do: many

  @doc """
  Items joined as a sentence lists them: `""`, `a`, `a and b`, `a, b and c`.
  """
  @spec and_list([String.t()]) :: String.t()
  def and_list([]), do: ""
  def and_list([one]), do: one

  def and_list(items) do
    {rest, [last]} = Enum.split(items, -1)
    Enum.join(rest, ", ") <> " and " <> last
  end
end
