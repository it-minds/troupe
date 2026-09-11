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

  defstruct max_turns: 50,
            max_input_tokens: 2_000_000,
            max_output_tokens: 200_000,
            max_wall_clock_ms: 3_600_000

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
  def exhausted?(%__MODULE__{} = b, usage, elapsed_ms) do
    usage.turns >= b.max_turns or usage.input_tokens >= b.max_input_tokens or
      usage.output_tokens >= b.max_output_tokens or elapsed_ms >= b.max_wall_clock_ms
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
