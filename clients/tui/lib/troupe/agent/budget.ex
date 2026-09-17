defmodule Troupe.Agent.Budget do
  @moduledoc "Per-branch, message-based budgets. No shared counter."

  alias Troupe.Agents.Definition

  @type usage :: %{
          turns: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_input_tokens: pos_integer(),
          max_output_tokens: pos_integer(),
          max_wall_clock_ms: pos_integer()
        }

  defstruct max_turns: 150,
            max_input_tokens: 6_000_000,
            max_output_tokens: 600_000,
            max_wall_clock_ms: 10_800_000

  @spec from_definition(Definition.t(), map() | keyword()) :: t()
  def from_definition(%Definition{} = def, overrides \\ %{}) do
    base = %__MODULE__{
      max_turns: def.max_turns,
      max_input_tokens: def.max_input_tokens,
      max_output_tokens: def.max_output_tokens,
      max_wall_clock_ms: def.max_wall_clock_ms
    }

    Enum.reduce(Map.new(overrides), base, fn
      {k, v}, acc when is_map_key(acc, k) and is_integer(v) and v > 0 -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end

  @doc "A child's budget: `fraction` of what remains of the parent's."
  @spec share(t(), usage(), float(), Definition.t()) :: t()
  def share(%__MODULE__{} = parent, usage, fraction, %Definition{} = child_def) do
    remaining_turns = max(parent.max_turns - usage.turns, 1)
    remaining_in = max(parent.max_input_tokens - usage.input_tokens, 1)
    remaining_out = max(parent.max_output_tokens - usage.output_tokens, 1)

    %__MODULE__{
      max_turns: min(max(trunc(remaining_turns * fraction), 1), child_def.max_turns),
      max_input_tokens: min(max(trunc(remaining_in * fraction), 1), child_def.max_input_tokens),
      max_output_tokens: min(max(trunc(remaining_out * fraction), 1), child_def.max_output_tokens),
      max_wall_clock_ms: min(parent.max_wall_clock_ms, child_def.max_wall_clock_ms)
    }
  end

  @spec exhausted?(t(), usage(), integer()) :: boolean()
  def exhausted?(%__MODULE__{} = b, usage, elapsed_ms),
    do: exhausted_dimension(b, usage, elapsed_ms) != nil

  @doc """
  Which ceiling was reached, or `nil`. `exhausted?/3` is an `or` across four
  limits and the agent used to be unable to say which one tripped, so the
  question it asked was the bare "budget exhausted" — this is what lets it say
  `turns 150/150` instead. Order is the order they are reported in, not a
  priority: at most one is usually over.
  """
  @spec exhausted_dimension(t(), usage(), integer()) :: :turns | :input | :output | :wall | nil
  def exhausted_dimension(%__MODULE__{} = b, usage, elapsed_ms) do
    cond do
      usage.turns >= b.max_turns -> :turns
      usage.input_tokens >= b.max_input_tokens -> :input
      usage.output_tokens >= b.max_output_tokens -> :output
      elapsed_ms >= b.max_wall_clock_ms -> :wall
      true -> nil
    end
  end

  @typedoc """
  What answering the budget question added to a budget. A grant is folded out of
  the log (`budget_ask_answered`), so it survives a restart — unlike the
  session-wide override, which lives in `Session.Approvals` and does not.
  """
  @type grant :: %{
          turns: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          wall_clock_ms: non_neg_integer()
        }

  @spec empty_grant() :: grant()
  def empty_grant, do: %{turns: 0, input_tokens: 0, output_tokens: 0, wall_clock_ms: 0}

  @doc """
  One more slice of the same size: `y` on the budget question buys the agent the
  budget it was given in the first place, again. The agent then asks again at the
  end of it, which is the point — a checkpoint every slice rather than the single
  irreversible `y` that used to make an agent's budget unlimited for good.
  """
  @spec slice(t()) :: grant()
  def slice(%__MODULE__{} = b) do
    %{
      turns: b.max_turns,
      input_tokens: b.max_input_tokens,
      output_tokens: b.max_output_tokens,
      wall_clock_ms: b.max_wall_clock_ms
    }
  end

  @spec add_grant(grant(), grant()) :: grant()
  def add_grant(a, b) do
    Map.new(empty_grant(), fn {k, _} -> {k, Map.get(a, k, 0) + Map.get(b, k, 0)} end)
  end

  @doc "The budget an agent is actually running on: its own plus everything granted."
  @spec with_grant(t(), grant()) :: t()
  def with_grant(%__MODULE__{} = b, grant) do
    %__MODULE__{
      max_turns: b.max_turns + Map.get(grant, :turns, 0),
      max_input_tokens: b.max_input_tokens + Map.get(grant, :input_tokens, 0),
      max_output_tokens: b.max_output_tokens + Map.get(grant, :output_tokens, 0),
      max_wall_clock_ms: b.max_wall_clock_ms + Map.get(grant, :wall_clock_ms, 0)
    }
  end

  @spec empty_usage() :: usage()
  def empty_usage, do: %{turns: 0, input_tokens: 0, output_tokens: 0}

  @doc """
  Adds one response's usage. `input_tokens` counts what the provider billed at
  close to full price — fresh input plus what it charged a premium to cache —
  and not what it served from the cache at a fraction of that, which on a long
  conversation is most of the prompt and would exhaust the budget for work the
  user is barely paying for.
  """
  @spec add_usage(usage(), map()) :: usage()
  def add_usage(usage, %{} = u) do
    %{
      turns: usage.turns + Map.get(u, :turns, 0),
      input_tokens: usage.input_tokens + Troupe.LLM.Provider.billed_input(u),
      output_tokens: usage.output_tokens + Map.get(u, :output_tokens, 0)
    }
  end
end
