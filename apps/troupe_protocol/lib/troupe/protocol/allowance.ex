defmodule Troupe.Protocol.Allowance do
  @moduledoc """
  What an agent is allowed where nothing sets less: Troupe's own defaults for the output
  cap of one model call and for each agent's budget (model calls, input and output tokens,
  working time, delegation depth).

  The harness reads them for its configuration's defaults (`Troupe.Config`,
  `Troupe.Config.Schema`) and for a budget's (`Troupe.Budget`), and the plane states them in
  `profile.get` as the limits a pod session runs under, since a pod reads no organisation
  layer and its profile sets only the output cap. Both read them here, where both can see
  them, so what the plane says a session is held to and what the harness holds it to are
  one number; core's test holds its defaults to these.

  The wall clock is working time: a turn from its start to its end, summed. Resting between
  turns and waiting on a person do not count.
  """

  @max_tokens 8192
  @max_turns 40
  @max_input_tokens 2_000_000
  @max_output_tokens 400_000
  @wall_clock_ms 30 * 60 * 1000
  @max_depth 3

  @doc "The most output tokens one model call asks for."
  @spec max_tokens() :: pos_integer()
  def max_tokens, do: @max_tokens

  @doc "Model calls an agent may make before its budget is spent."
  @spec max_turns() :: pos_integer()
  def max_turns, do: @max_turns

  @doc "Input tokens an agent may spend."
  @spec max_input_tokens() :: pos_integer()
  def max_input_tokens, do: @max_input_tokens

  @doc "Output tokens an agent may spend."
  @spec max_output_tokens() :: pos_integer()
  def max_output_tokens, do: @max_output_tokens

  @doc "How long an agent may work, in working time, in milliseconds."
  @spec wall_clock_ms() :: pos_integer()
  def wall_clock_ms, do: @wall_clock_ms

  @doc "How deep agents may delegate; 1 means the root alone may."
  @spec max_depth() :: non_neg_integer()
  def max_depth, do: @max_depth
end
