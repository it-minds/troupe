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
            original: nil,
            # Limits the person lifted with `always`, each for the rest of the session and
            # each on its own: the others still ask when they are reached (Decision 687).
            lifted: []

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_input_tokens: pos_integer(),
          max_output_tokens: pos_integer(),
          wall_clock_ms: pos_integer(),
          turns: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          started_at: integer() | nil,
          original: slice() | nil,
          lifted: [exhaustion()]
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
  further calls rather than one more. A lifted limit never stops it.
  """
  @spec check(t()) :: :ok | {:exhausted, exhaustion()}
  def check(%__MODULE__{} = b) do
    [
      max_turns: b.turns >= b.max_turns,
      max_input_tokens: b.input_tokens >= b.max_input_tokens,
      max_output_tokens: b.output_tokens >= b.max_output_tokens,
      wall_clock: elapsed(b) >= b.wall_clock_ms
    ]
    |> Enum.find(fn {limit, spent?} -> spent? and limit not in b.lifted end)
    |> case do
      nil -> :ok
      {limit, true} -> {:exhausted, limit}
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

  `share` is the child definition's `budget_share`, taken of the tokens and time the
  parent has left: a child's usage is charged back to its parent and its clock runs on
  the parent's time, so those really come out of the parent's allowance. Turns do not —
  a child's turns cost its parent none — so a delegate gets the turns its parent was
  first given, which its definition's `max_turns` may lower (Decision 687). A share of
  the parent's *remaining* turns shrank with every turn the parent took, until an
  `explore` asked to read one app ran out before it could report.

  A limit the parent lifted is lifted for the child as well, and the child's figure for
  it is a share of the parent's first allowance: of a limit it has passed, the parent
  has nothing left to share.
  """
  @spec slice(t(), float()) :: t()
  def slice(%__MODULE__{} = parent, share) when is_float(share) and share > 0 do
    share = min(share, 1.0)
    first = original(parent)

    %__MODULE__{
      max_turns: first.turns,
      max_input_tokens:
        max(trunc(left(parent, :max_input_tokens, remaining_input(parent), first.input_tokens) * share), 1),
      max_output_tokens:
        max(trunc(left(parent, :max_output_tokens, remaining_output(parent), first.output_tokens) * share), 1),
      wall_clock_ms: max(trunc(left(parent, :wall_clock, remaining_ms(parent), first.wall_clock_ms) * share), 1_000),
      lifted: parent.lifted
    }
  end

  @doc """
  Lift one limit for the rest of the session: `always` on the budget question, which
  asked about that limit alone (Decision 687). The others still ask when they are reached.
  """
  @spec lift(t(), exhaustion()) :: t()
  def lift(%__MODULE__{} = b, limit), do: %{b | lifted: Enum.uniq(b.lifted ++ [limit])}

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

  defp left(%__MODULE__{lifted: lifted}, limit, remaining, first),
    do: if(limit in lifted, do: first, else: remaining)

  defp remaining_input(b), do: max(b.max_input_tokens - b.input_tokens, 0)
  defp remaining_output(b), do: max(b.max_output_tokens - b.output_tokens, 0)
  defp remaining_ms(b), do: max(b.wall_clock_ms - elapsed(b), 0)
end
