defmodule Troupe.Budget do
  @moduledoc """
  A single agent's limits, enforced by that agent alone.

  There is no shared counter process: a parent computes a slice for each delegation
  from the child's `budget_share`, hands it over in the child's spec, and charges the
  usage the child reports back. That keeps budget enforcement a local decision and
  keeps it correct when a subagent subtree dies.
  """

  alias Troupe.LLM.Usage

  defstruct max_turns: 40,
            max_input_tokens: 2_000_000,
            max_output_tokens: 400_000,
            wall_clock_ms: 30 * 60 * 1000,
            turns: 0,
            input_tokens: 0,
            output_tokens: 0,
            started_at: nil,
            # The allowance as first given, once a grant has enlarged it: what `allow` on the
            # budget question buys again (Decision 660). `nil` until then.
            original: nil

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_input_tokens: pos_integer(),
          max_output_tokens: pos_integer(),
          wall_clock_ms: pos_integer(),
          turns: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          started_at: integer() | nil,
          original: slice() | nil
        }

  @type exhaustion :: :max_turns | :max_input_tokens | :max_output_tokens | :wall_clock

  @typedoc "One allowance, the size the agent was given in the first place."
  @type slice :: %{
          turns: pos_integer(),
          input_tokens: pos_integer(),
          output_tokens: pos_integer(),
          wall_clock_ms: pos_integer()
        }

  @doc "Start the wall clock. Called when an agent begins, and on replay."
  @spec start(t()) :: t()
  def start(%__MODULE__{started_at: nil} = budget) do
    %{budget | started_at: System.monotonic_time(:millisecond)}
  end

  def start(%__MODULE__{} = budget), do: budget

  @doc """
  Whether another LLM request is allowed, and if not, which limit stopped it.

  Checked immediately before starting a stream, so an exhausted agent makes zero
  further calls rather than one more.
  """
  @spec check(t()) :: :ok | {:exhausted, exhaustion()}
  def check(%__MODULE__{} = b) do
    cond do
      b.turns >= b.max_turns -> {:exhausted, :max_turns}
      b.input_tokens >= b.max_input_tokens -> {:exhausted, :max_input_tokens}
      b.output_tokens >= b.max_output_tokens -> {:exhausted, :max_output_tokens}
      elapsed(b) >= b.wall_clock_ms -> {:exhausted, :wall_clock}
      true -> :ok
    end
  end

  @doc "Count one LLM request against the turn limit."
  @spec charge_turn(t()) :: t()
  def charge_turn(%__MODULE__{} = b), do: %{b | turns: b.turns + 1}

  @doc """
  Add token usage, from this agent's own response or a child's report.

  Input is charged at what the provider billed at close to full price
  (`Usage.billed_input/1`): fresh tokens and cache writes, not cache reads.
  A long conversation re-reads its whole prompt every turn, and on an OpenAI-compatible
  provider nearly all of that is served from the cache at a tenth of the price; a
  budget that counted it exhausted `max_input_tokens` roughly ten times early, on work
  the user was barely paying for (Decision 657). The prompt's length is
  `Usage.total_input/1`, and that is what compaction measures.
  """
  @spec charge_usage(t(), Usage.t()) :: t()
  def charge_usage(%__MODULE__{} = b, %Usage{} = usage) do
    %{
      b
      | input_tokens: b.input_tokens + Usage.billed_input(usage),
        output_tokens: b.output_tokens + usage.output_tokens
    }
  end

  @doc """
  Carve a slice out for a delegation.

  `share` is the child definition's `budget_share`. Turns are floored at 1 so a
  delegation always gets at least one chance to answer; token and time slices are
  taken from what the parent has left, not from its original allowance.
  """
  @spec slice(t(), float()) :: t()
  def slice(%__MODULE__{} = parent, share) when is_float(share) and share > 0 do
    share = min(share, 1.0)

    %__MODULE__{
      max_turns: max(trunc((parent.max_turns - parent.turns) * share), 1),
      max_input_tokens: max(trunc(remaining_input(parent) * share), 1),
      max_output_tokens: max(trunc(remaining_output(parent) * share), 1),
      wall_clock_ms: max(trunc(remaining_ms(parent) * share), 1_000)
    }
  end

  @doc """
  One more slice of the same size (Decision 660): `allow` on the budget question buys the
  agent the budget it was given in the first place, again. It asks again at the end of
  that — a checkpoint every slice rather than one irreversible yes.
  """
  @spec grant(t()) :: t()
  def grant(%__MODULE__{} = b) do
    slice = original(b)

    %{
      b
      | max_turns: b.max_turns + slice.turns,
        max_input_tokens: b.max_input_tokens + slice.input_tokens,
        max_output_tokens: b.max_output_tokens + slice.output_tokens,
        wall_clock_ms: b.wall_clock_ms + slice.wall_clock_ms,
        original: slice
    }
  end

  @doc "The allowance as first given: what a grant adds."
  @spec original(t()) :: slice()
  def original(%__MODULE__{original: %{} = slice}), do: slice

  def original(%__MODULE__{} = b) do
    %{
      turns: b.max_turns,
      input_tokens: b.max_input_tokens,
      output_tokens: b.max_output_tokens,
      wall_clock_ms: b.wall_clock_ms
    }
  end

  @doc """
  Usage consumed so far, for reporting back to a parent. `input_tokens` is what was
  billed, so a parent charging it counts nothing twice.
  """
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{} = b) do
    %Usage{input_tokens: b.input_tokens, output_tokens: b.output_tokens}
  end

  defp elapsed(%__MODULE__{started_at: nil}), do: 0
  defp elapsed(%__MODULE__{started_at: at}), do: System.monotonic_time(:millisecond) - at

  defp remaining_input(b), do: max(b.max_input_tokens - b.input_tokens, 0)
  defp remaining_output(b), do: max(b.max_output_tokens - b.output_tokens, 0)
  defp remaining_ms(b), do: max(b.wall_clock_ms - elapsed(b), 0)
end
