defmodule Troupe.A2A.Streams do
  @moduledoc """
  How many streams are open, and whether one more may be.

  A `message/stream` is a WebSocket held open to a pod for as long as the caller keeps
  reading, and a replica can hold only so many. The count is a `Registry` with one key
  per stream: an entry dies with the process that holds it, so a stream whose handler
  crashed is not counted against the next caller, and there is no counter to decrement
  in an `after` that might not run.

  The check and the register are two steps, so two callers arriving at once at the
  limit can both get in. That is a limit off by one under a race, not a hole, and a
  lock across the two would put every stream's start behind one process.
  """

  @registry __MODULE__

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc "Take a slot for the calling process, or say the replica is full."
  @spec acquire() :: {:ok, reference()} | {:error, :too_many_streams}
  def acquire do
    if count() >= Troupe.A2A.max_streams() do
      {:error, :too_many_streams}
    else
      key = make_ref()
      {:ok, _owner} = Registry.register(@registry, key, nil)
      {:ok, key}
    end
  end

  @doc """
  Give a slot back.

  Explicit rather than left to the process exiting, because an HTTP/1.1 connection
  process outlives the request it served: the next request on the same connection
  would otherwise start with a slot already held.
  """
  @spec release(reference()) :: :ok
  def release(key), do: Registry.unregister(@registry, key)

  @doc "Streams open on this replica."
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)
end
