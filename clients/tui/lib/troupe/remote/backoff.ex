defmodule Troupe.Remote.Backoff do
  @moduledoc """
  Reconnect delays: exponential with full jitter, capped. A connection that
  comes back resets it, so a flapping link does not inherit yesterday's delay.
  """

  @type t :: %{attempt: non_neg_integer(), base: pos_integer(), max: pos_integer()}

  @spec new(keyword()) :: t()
  def new(opts \\ []),
    do: %{
      attempt: 0,
      base: Keyword.get(opts, :base, 250),
      max: Keyword.get(opts, :max, 30_000)
    }

  @doc "The next delay in milliseconds, and the backoff to carry forward."
  @spec next(t()) :: {pos_integer(), t()}
  def next(%{attempt: attempt, base: base, max: max} = backoff) do
    ceiling = min(base * Integer.pow(2, min(attempt, 16)), max)
    delay = :rand.uniform(max(ceiling, 1))
    {delay, %{backoff | attempt: attempt + 1}}
  end

  @spec reset(t()) :: t()
  def reset(backoff), do: %{backoff | attempt: 0}
end
