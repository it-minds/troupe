defmodule Troupe.Ctl.Verify do
  @moduledoc """
  Walk a session's hash chain and name the first event that does not fit.

  Every durable event carries `prev_hash`, the digest of the previous event's canonical
  JSON computed over the event *without* its own `prev_hash`. That makes the log
  checkable by whoever holds it, without trusting whoever handed it over — which is the
  point, because in a remote installation the storage, the worker and the plane are all
  things a user is being asked to trust.

  Two ways in, and both matter. A log file or a decrypted segment is checked **offline**,
  with no daemon and no plane, which is what an auditor with a copy of the bytes can do.
  A live session is checked by replaying it from `seq` 0 over the protocol, which checks
  what a client would actually have been served.
  """

  alias Troupe.Protocol.{Client, Event}

  @type outcome ::
          {:ok, %{events: non_neg_integer(), head_hash: String.t() | nil}}
          | {:error, {:chain_broken, non_neg_integer(), atom()}}
          | {:error, term()}

  @doc "Check a JSONL log or a decrypted segment on disk."
  @spec file(Path.t()) :: outcome()
  def file(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> decode() |> chain()
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @doc "Check what a daemon serves for a session, by replaying it from the beginning."
  @spec session(pid(), String.t(), timeout()) :: outcome()
  def session(client, session_id, timeout \\ 60_000) do
    case Client.subscribe(client, "session:" <> session_id, from_seq: 0) do
      {:ok, %{"head_seq" => 0}} -> {:ok, %{events: 0, head_hash: nil}}
      {:ok, %{"head_seq" => head}} -> head |> collect(timeout) |> chain()
      {:error, error} -> {:error, error}
    end
  end

  @doc "Check a list of events that is already in hand."
  @spec chain([Event.t()]) :: outcome()
  def chain([]), do: {:ok, %{events: 0, head_hash: nil}}

  def chain(events) do
    case Event.verify(events) do
      :ok -> {:ok, %{events: length(events), head_hash: Event.hash(List.last(events))}}
      {:error, seq, reason} -> {:error, {:chain_broken, seq, reason}}
    end
  end

  @doc "What happened, in a sentence, and the exit code that goes with it."
  @spec describe(outcome()) :: {String.t(), non_neg_integer()}
  def describe({:ok, %{events: 0}}), do: {"the log is empty", 0}

  def describe({:ok, %{events: count, head_hash: head}}) do
    {"#{count} events verify; the head is #{head}", 0}
  end

  def describe({:error, {:chain_broken, seq, :prev_hash_mismatch}}) do
    {"the chain breaks at seq #{seq}: its prev_hash does not match the event before it", 1}
  end

  def describe({:error, {:chain_broken, seq, :seq_gap}}) do
    {"the chain breaks at seq #{seq}: the sequence skips", 1}
  end

  def describe({:error, {:unreadable, path, reason}}) do
    {"#{path} could not be read: #{:file.format_error(reason)}", 2}
  end

  def describe({:error, %{message: message}}), do: {"the daemon refused: #{message}", 1}
  def describe({:error, reason}), do: {"verification failed: #{inspect(reason)}", 1}

  defp decode(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
  end

  defp collect(count, timeout, acc \\ [])
  defp collect(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect(count, timeout, acc) do
    receive do
      # Ephemerals carry no `seq` and are not part of the chain.
      {:troupe_event, _topic, _session_id, %Event{seq: nil}} -> collect(count, timeout, acc)
      {:troupe_event, _topic, _session_id, event} -> collect(count - 1, timeout, [event | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
