defmodule Troupe.Gateway.Transport do
  @moduledoc """
  What a connection needs from the thing underneath it, and nothing more.

  A `Gateway.Connection` is the protocol: the handshake, the scopes, the subscriptions,
  the backpressure policy. None of that is about sockets, and none of it should have to
  be written twice because a worker pod is reached through an Ingress and a laptop is
  reached through a Unix socket.

  Two implementations.

  * `{:tcp, socket}` — NDJSON over `:gen_tcp`, the local daemon and the pod's own
    listener. Reads arrive as `{:tcp, socket, data}` and the connection asks for the
    next packet itself.
  * `{:relay, pid}` — one message per WebSocket text frame, where the frames are owned
    by a `WebSock` process that cannot also be the connection. Reads arrive as
    `{:transport_data, data}` and writes go out as `{:transport_out, iodata}` for that
    process to push.

  The relay is a pair of `send/2` calls rather than a callback because the two processes
  must never wait on each other: that is the same rule the writer exists to keep, and a
  transport that could block would quietly reintroduce the backpressure problem
  underneath the code that solves it.
  """

  @type t :: {:tcp, :gen_tcp.socket()} | {:relay, pid()}

  @doc """
  Ask for the next read.

  A no-op on the relay: frames are pushed by whoever owns them, and there is no
  `active: :once` to re-arm.
  """
  @spec activate(t()) :: :ok
  def activate({:tcp, socket}), do: with({:error, _reason} <- :inet.setopts(socket, active: :once), do: :ok)
  def activate({:relay, _pid}), do: :ok

  @doc "Write, blocking if the peer is not reading. Called only from `Gateway.Writer`."
  @spec write(t(), iodata()) :: :ok | {:error, term()}
  def write({:tcp, socket}, iodata), do: :gen_tcp.send(socket, iodata)

  def write({:relay, pid}, iodata) do
    send(pid, {:transport_out, iodata})
    :ok
  end

  @doc "Close. Idempotent, because both halves of a connection may get here."
  @spec close(t()) :: :ok
  def close({:tcp, socket}), do: :gen_tcp.close(socket)

  def close({:relay, pid}) do
    send(pid, :transport_close)
    :ok
  end
end
