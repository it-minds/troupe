defmodule Troupe.Agent.Headroom do
  @moduledoc """
  How much of every limit an agent has spent, as one pure map (Decision 655).

  There are five ceilings a turn can hit and they are not interchangeable: four are
  the agent's own budget (`Troupe.Budget`) and the fifth is the model's context window,
  which belongs to the provider and answers a 400 rather than a question. They are
  computed in one place so the warning a person sees before anything stops, the
  `headroom` a client draws from `agent_state`, and the sentence that names which
  ceiling is near all read the same numbers.
  """

  alias Troupe.Budget

  @type entry :: %{used: non_neg_integer(), limit: pos_integer(), fraction: float()}
  @type t :: %{turns: entry(), input: entry(), output: entry(), wall: entry(), context: entry()}

  @dimensions [:turns, :input, :output, :wall, :context]

  @doc "Every dimension this module knows, in the order they are reported."
  @spec dimensions() :: [atom()]
  def dimensions, do: @dimensions

  @doc """
  The five fractions. `prompt_tokens` is the size of the last prompt the model saw —
  every token it contained, cached or not, which is `Troupe.LLM.Usage.total_input/1` and
  never the provider's own `input_tokens` (Decision 657) — and `window` the model's
  context window; `0` for the first, before any response, reads as an empty context
  rather than a full one.
  """
  @spec of(Budget.t(), non_neg_integer(), pos_integer()) :: t()
  def of(%Budget{} = b, prompt_tokens, window) do
    %{
      turns: entry(b.turns, b.max_turns),
      input: entry(b.input_tokens, b.max_input_tokens),
      output: entry(b.output_tokens, b.max_output_tokens),
      wall: entry(elapsed(b), b.wall_clock_ms),
      context: entry(prompt_tokens, window)
    }
  end

  defp entry(used, limit) when is_integer(limit) and limit > 0 do
    used = max(used, 0)
    %{used: used, limit: limit, fraction: used / limit}
  end

  defp entry(used, _limit), do: %{used: max(used, 0), limit: 1, fraction: 0.0}

  defp elapsed(%Budget{started_at: nil}), do: 0
  defp elapsed(%Budget{started_at: at}), do: max(System.monotonic_time(:millisecond) - at, 0)

  @doc "The dimension closest to its ceiling."
  @spec tightest(t()) :: {atom(), entry()}
  def tightest(headroom) do
    dim = Enum.max_by(@dimensions, &headroom[&1].fraction)
    {dim, headroom[dim]}
  end

  @doc """
  Dimensions that have crossed `threshold` and are not in `already`, tightest first: what
  becomes a `budget_warning`, one per dimension per agent, so a warning cannot become a
  per-turn nag.
  """
  @spec crossed(t(), float(), Enumerable.t()) :: [{atom(), entry()}]
  def crossed(headroom, threshold, already) do
    warned = MapSet.new(already)

    @dimensions
    |> Enum.reject(&MapSet.member?(warned, &1))
    |> Enum.filter(&(headroom[&1].fraction >= threshold))
    |> Enum.map(&{&1, headroom[&1]})
    |> Enum.sort_by(fn {_dim, e} -> -e.fraction end)
  end

  @doc "The map as it crosses the wire: fractions and counts, string keys."
  @spec to_json(t()) :: map()
  def to_json(headroom) do
    Map.new(headroom, fn {dim, %{used: used, limit: limit, fraction: fraction}} ->
      {to_string(dim), %{"used" => used, "limit" => limit, "fraction" => Float.round(fraction, 3)}}
    end)
  end

  @doc "What to call a dimension in a sentence a person reads."
  @spec label(atom()) :: String.t()
  def label(:turns), do: "turns"
  def label(:input), do: "input tokens"
  def label(:output), do: "output tokens"
  def label(:wall), do: "wall clock"
  def label(:context), do: "context window"
  def label(other), do: to_string(other)

  @doc "One dimension as `input tokens 4.9M/6.0M (82%)`."
  @spec describe(atom(), entry()) :: String.t()
  def describe(dim, %{used: used, limit: limit, fraction: fraction}) do
    "#{label(dim)} #{value(dim, used)}/#{value(dim, limit)} (#{percent(fraction)})"
  end

  @doc "A fraction as a whole-number percentage."
  @spec percent(float()) :: String.t()
  def percent(fraction), do: "#{round(fraction * 100)}%"

  defp value(:wall, ms), do: duration(ms)
  defp value(:turns, n), do: Integer.to_string(n)
  defp value(_dim, n), do: tokens(n)

  defp duration(ms) when ms >= 3_600_000, do: "#{Float.round(ms / 3_600_000, 1)}h"
  defp duration(ms) when ms >= 60_000, do: "#{div(ms, 60_000)}m"
  defp duration(ms), do: "#{div(ms, 1000)}s"

  defp tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp tokens(n), do: Integer.to_string(n)
end
