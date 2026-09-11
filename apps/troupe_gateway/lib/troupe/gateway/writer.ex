defmodule Troupe.Gateway.Writer do
  @moduledoc """
  The write side of one client socket, in its own process.

  A transport write blocks once the kernel and driver buffers fill, and they fill as
  soon as a client stops reading. If the connection process did its own writing it
  would block there, its mailbox would grow without limit while it did, and the
  backpressure logic — which lives in that very process — would not run at all.

  So writes are a `send/2` to this process, which can afford to block. The connection
  counts what it has handed over and stops handing over more past its bounds; this
  process acknowledges each write as it completes, which is how those counts come back
  down. Neither process ever waits on the other.

  Two kinds of message, because they need different fates when a client falls behind:

  * **queued** writes — events — can be thrown away by `discard/1`.
  * **urgent** writes — responses the client is waiting on, and the `resync_required`
    that explains why its subscription ended — cannot. `resync_required` is queued
    behind the very backlog it is about to discard, so without this it would be the
    first casualty of its own arrival.
  """

  alias Troupe.Gateway.Transport

  @type kind :: :durable | :ephemeral

  @doc """
  Start a writer for a transport.

  Linked: neither half of a connection outlives the other.
  """
  @spec start_link(Troupe.Gateway.Transport.t(), pid()) :: {:ok, pid()}
  def start_link(transport, owner), do: {:ok, spawn_link(fn -> loop(transport, owner) end)}

  @doc "Queue a droppable message. Never blocks, and never fails."
  @spec write(pid(), kind(), iodata()) :: non_neg_integer()
  def write(writer, kind, iodata) do
    bytes = IO.iodata_length(iodata)
    send(writer, {:write, kind, iodata, bytes})
    bytes
  end

  @doc "Queue a message `discard/1` must not throw away."
  @spec write_urgent(pid(), iodata()) :: non_neg_integer()
  def write_urgent(writer, iodata) do
    bytes = IO.iodata_length(iodata)
    send(writer, {:write_urgent, iodata, bytes})
    bytes
  end

  @doc """
  Throw away every queued write, returning what they cost to the owner's budget.

  Not data loss: it is only ever called alongside `resync_required`, at which point the
  client is going to re-subscribe from its own last `seq` and be sent all of it again —
  and the queue is exactly the memory we need back in order to say so.
  """
  @spec discard(pid()) :: :ok
  def discard(writer) do
    send(writer, :discard)
    :ok
  end

  @doc """
  Wait until everything queued before this call has been written.

  Called from the connection's `terminate/2`, because the connection closes the socket
  there and a refusal the client still has to read — `not_initialized`, an unsupported
  version — would otherwise be thrown away with it.
  """
  @spec flush(pid(), timeout()) :: :ok
  def flush(writer, timeout \\ 1_000) do
    reference = make_ref()
    send(writer, {:flush, self(), reference})

    receive do
      {:flushed, ^reference} -> :ok
    after
      timeout -> :ok
    end
  end

  defp loop(transport, owner) do
    receive do
      {:write, kind, iodata, bytes} ->
        put(transport, owner, iodata, {:written, kind, bytes})

      {:write_urgent, iodata, bytes} ->
        put(transport, owner, iodata, {:written, :control, bytes})

      :discard ->
        # Only `{:write, ...}` is matched, so anything urgent already queued stays
        # where it is and goes out next.
        Enum.each(drop_queued(%{}), &send(owner, &1))
        loop(transport, owner)

      {:flush, from, reference} ->
        send(from, {:flushed, reference})
        loop(transport, owner)
    end
  end

  defp put(transport, owner, iodata, ack) do
    case Transport.write(transport, iodata) do
      :ok ->
        send(owner, ack)
        loop(transport, owner)

      {:error, reason} ->
        # A failed send says nothing about how much of it arrived, so the stream cannot
        # be trusted afterwards. The connection tears down and the client reconnects
        # and replays, which is a defined recovery; writing more onto a half-written
        # line is not.
        send(owner, {:write_failed, reason})
    end
  end

  defp drop_queued(dropped) do
    receive do
      {:write, kind, _iodata, bytes} ->
        drop_queued(Map.update(dropped, kind, bytes, &(&1 + bytes)))
    after
      0 -> Enum.map(dropped, fn {kind, bytes} -> {:written, kind, bytes} end)
    end
  end
end
