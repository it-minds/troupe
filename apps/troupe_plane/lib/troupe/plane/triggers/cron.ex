defmodule Troupe.Plane.Triggers.Cron do
  @moduledoc """
  Five-field cron, enough for a schedule and no more.

      minute hour day-of-month month day-of-week

  Each field takes `*`, `*/n`, a number, a list `a,b`, a range `a-b`, or a stepped range
  `a-b/n`. Day-of-week is `0`–`7` with both `0` and `7` Sunday, and when both day fields
  are restricted a minute matches if *either* does, which is what every cron since the
  first has meant by it. No names, no `@daily`, no seconds: a dependency would bring
  those and a good deal else, and a schedule an admin cannot read at a glance is one
  they will get wrong.

  Times are UTC. There is no time zone database in this release, and pretending to
  support `tz` by ignoring it would fire a nightly job at the wrong hour and say nothing.
  """

  @type t :: %{
          minute: MapSet.t(),
          hour: MapSet.t(),
          dom: MapSet.t(),
          month: MapSet.t(),
          dow: MapSet.t(),
          dom_any: boolean(),
          dow_any: boolean()
        }

  @ranges [minute: 0..59, hour: 0..23, dom: 1..31, month: 1..12, dow: 0..7]

  # How far back `previous/2` will look before giving up: five years covers `0 0 29 2 *`
  # from any date, and anything else a five-field expression can say is inside a year.
  # Days that cannot match are skipped whole, so the bound is a ceiling and not a cost.
  @max_lookback_minutes 60 * 24 * 366 * 5

  @doc "Parse an expression, or say which field is wrong."
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(expression) when is_binary(expression) do
    case String.split(expression, ~r/\s+/, trim: true) do
      [minute, hour, dom, month, dow] ->
        with {:ok, minute} <- field(minute, :minute),
             {:ok, hour} <- field(hour, :hour),
             {:ok, dom} <- field(dom, :dom),
             {:ok, month} <- field(month, :month),
             {:ok, dow} <- field(dow, :dow) do
          {:ok,
           %{
             minute: minute,
             hour: hour,
             dom: dom,
             month: month,
             dow: MapSet.new(dow, &rem(&1, 7)),
             dom_any: dom == MapSet.new(1..31),
             dow_any: MapSet.new(dow, &rem(&1, 7)) == MapSet.new(0..6)
           }}
        end

      fields ->
        {:error, "expected five fields, got #{length(fields)}"}
    end
  end

  def parse(_other), do: {:error, "a cron expression is a string"}

  @doc "Whether a minute matches. Seconds are ignored, as cron ignores them."
  @spec matches?(t(), DateTime.t()) :: boolean()
  def matches?(cron, %DateTime{} = at) do
    MapSet.member?(cron.minute, at.minute) and MapSet.member?(cron.hour, at.hour) and
      MapSet.member?(cron.month, at.month) and day_matches?(cron, at)
  end

  # Both restricted: either will do. One restricted: that one decides. Neither: any day.
  defp day_matches?(cron, at) do
    dom? = MapSet.member?(cron.dom, at.day)
    dow? = MapSet.member?(cron.dow, rem(Date.day_of_week(at), 7))

    cond do
      cron.dom_any and cron.dow_any -> true
      cron.dom_any -> dow?
      cron.dow_any -> dom?
      true -> dom? or dow?
    end
  end

  @doc """
  The latest matching minute at or before `now`, or `nil` if there is none in a year.

  Walks back a minute at a time within a day and a day at a time when the day cannot
  match, which keeps `0 3 * * 1-5` cheap and `0 0 29 2 *` bounded.
  """
  @spec previous(t(), DateTime.t()) :: DateTime.t() | nil
  def previous(cron, %DateTime{} = now) do
    now |> floor_minute() |> walk_back(cron, @max_lookback_minutes)
  end

  defp walk_back(_at, _cron, budget) when budget <= 0, do: nil

  defp walk_back(at, cron, budget) do
    cond do
      matches?(cron, at) ->
        at

      MapSet.member?(cron.month, at.month) and day_matches?(cron, at) ->
        walk_back(DateTime.add(at, -60, :second), cron, budget - 1)

      true ->
        # Nothing in this day can match, so jump to the last minute of the day before.
        start_of_day = %{at | hour: 0, minute: 0}
        skipped = at.hour * 60 + at.minute + 1
        walk_back(DateTime.add(start_of_day, -60, :second), cron, budget - skipped)
    end
  end

  @doc "A time with its seconds and smaller dropped, which is the unit cron thinks in."
  @spec floor_minute(DateTime.t()) :: DateTime.t()
  def floor_minute(%DateTime{} = at), do: %{at | second: 0, microsecond: {0, 0}}

  # -- fields -----------------------------------------------------------------

  defp field(text, name) do
    range = Keyword.fetch!(@ranges, name)

    text
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case part(part, range) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(values))}}
        {:error, reason} -> {:halt, {:error, "#{name}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, set} -> if MapSet.size(set) == 0, do: {:error, "#{name}: empty"}, else: {:ok, set}
      error -> error
    end
  end

  defp part("*", range), do: {:ok, range}

  defp part("*/" <> step, range) do
    with {:ok, step} <- step(step), do: {:ok, Enum.take_every(range, step)}
  end

  defp part(text, range) do
    case String.split(text, "/", parts: 2) do
      [span, step] ->
        with {:ok, step} <- step(step), {:ok, first..last//_} <- span(span, range) do
          {:ok, Enum.take_every(first..last//1, step)}
        end

      [span] ->
        span(span, range)
    end
  end

  defp span(text, range) do
    case String.split(text, "-", parts: 2) do
      [a, b] ->
        with {:ok, a} <- number(a, range), {:ok, b} <- number(b, range), do: ascending(a, b)

      [a] ->
        with {:ok, a} <- number(a, range), do: {:ok, a..a//1}
    end
  end

  defp ascending(a, b) when a <= b, do: {:ok, a..b//1}
  defp ascending(a, b), do: {:error, "#{a}-#{b} runs backwards"}

  defp number(text, range) do
    case Integer.parse(text) do
      {n, ""} -> if n in range, do: {:ok, n}, else: {:error, "#{n} is outside #{inspect(range)}"}
      _ -> {:error, "#{inspect(text)} is not a number"}
    end
  end

  defp step(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "step #{inspect(text)} is not a positive number"}
    end
  end
end
