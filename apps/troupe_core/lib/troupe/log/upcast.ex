defmodule Troupe.Log.Upcast do
  @moduledoc """
  Reading a log written by an older Troupe.

  Every durable event carries a schema version `v`. A session started a year ago and
  activated today is replayed through this chain, which brings each event up to the
  current version one step at a time — `1 -> 2 -> 3`, never `1 -> 3` — so adding a
  version means writing one function and not revisiting every older one.

  The rule that makes this tractable: **an upcaster may add and rename, never drop.** A
  replay has to produce what the session actually did, and an upcaster that discarded a
  field would be rewriting history to suit today's code. Where a field genuinely has no
  modern equivalent it is kept under its old name; the fold ignores what it does not
  know, which is the same tolerance a client is asked for.

  The hash chain is *not* recomputed. `prev_hash` covers the event as it was written,
  and upcasting changes the in-memory shape rather than the bytes on disk: a log from
  2025 still verifies against what it was sealed with, and `troupe verify` reads the raw
  file rather than coming through here.
  """

  alias Troupe.Protocol.Event

  @current 1

  @doc "The version this build writes."
  @spec current() :: pos_integer()
  def current, do: @current

  @doc """
  Bring one event up to the current version.

  An event from a *newer* version than this build knows is returned unchanged rather
  than rejected: a client one release behind should degrade to ignoring fields it does
  not understand, which is exactly what the fold does anyway.
  """
  @spec event(Event.t()) :: Event.t()
  def event(%Event{v: v} = event) when v >= @current, do: event
  def event(%Event{} = event), do: step(event)

  defp step(%Event{v: v} = event) when v >= @current, do: event

  defp step(%Event{v: v} = event) do
    event |> upcast(v) |> Map.put(:v, v + 1) |> step()
  end

  # One clause per version, and each one only knows how to get from `n` to `n + 1`.
  #
  # There are no historical versions yet: version 1 is the first released shape. The
  # chain exists now rather than later because retrofitting it to a log format already
  # in the field is the part that goes wrong — the fixtures under
  # `test/fixtures/logs/` are what keep it honest.
  defp upcast(event, _version), do: event

  @doc "Bring a whole log up to date, in order."
  @spec log([Event.t()]) :: [Event.t()]
  def log(events), do: Enum.map(events, &event/1)

  @doc """
  Whether a log is entirely from versions this build understands.

  A log with an event from the future is still replayable — unknown fields are ignored —
  but it is worth saying so, because a pod running an old image against a session an
  newer one wrote is a deployment mistake rather than a data one.
  """
  @spec from_the_future([Event.t()]) :: [pos_integer()]
  def from_the_future(events) do
    events |> Enum.map(& &1.v) |> Enum.filter(&(&1 > @current)) |> Enum.uniq() |> Enum.sort()
  end
end
