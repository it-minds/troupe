defmodule Troupe.Budget do
  @moduledoc """
  A single agent's limits, enforced by that agent alone.

  There is no shared counter process: a parent computes a slice for each delegation
  from the child's `budget_share`, hands it over in the child's spec, and charges the
  usage the child reports back. That keeps budget enforcement a local decision and
  keeps it correct when a subagent subtree dies.
  """

  defstruct max_turns: 40,
            max_input_tokens: 2_000_000,
            max_output_tokens: 400_000,
            wall_clock_ms: 30 * 60 * 1000,
            turns: 0,
            input_tokens: 0,
            output_tokens: 0,
            started_at: nil

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_input_tokens: pos_integer(),
          max_output_tokens: pos_integer(),
          wall_clock_ms: pos_integer(),
          turns: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          started_at: integer() | nil
        }

  @type exhaustion :: :max_turns | :max_input_tokens | :max_output_tokens | :wall_clock

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

  @doc "Add token usage, from this agent's own response or a child's report."
  @spec charge_usage(t(), Troupe.LLM.Usage.t()) :: t()
  def charge_usage(%__MODULE__{} = b, %Troupe.LLM.Usage{} = usage) do
    %{
      b
      | input_tokens: b.input_tokens + usage.input_tokens,
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

  @doc "Usage consumed so far, for reporting back to a parent."
  @spec usage(t()) :: Troupe.LLM.Usage.t()
  def usage(%__MODULE__{} = b) do
    %Troupe.LLM.Usage{input_tokens: b.input_tokens, output_tokens: b.output_tokens}
  end

  defp elapsed(%__MODULE__{started_at: nil}), do: 0
  defp elapsed(%__MODULE__{started_at: at}), do: System.monotonic_time(:millisecond) - at

  defp remaining_input(b), do: max(b.max_input_tokens - b.input_tokens, 0)
  defp remaining_output(b), do: max(b.max_output_tokens - b.output_tokens, 0)
  defp remaining_ms(b), do: max(b.wall_clock_ms - elapsed(b), 0)
end
