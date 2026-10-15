defmodule Troupe.Plane.Control.Replay do
  @moduledoc """
  A TLS handshake on a control socket whose first byte has already been read.

  The control port speaks TLS and plaintext both, and the connection reads one byte to
  learn which: a TLS handshake opens with `22`, a JSON-RPC line with `{`. A plaintext
  line reader takes that byte as the start of its buffer. `:ssl` reads the socket itself,
  so it is given the socket through this module, as its transport (`cb_info`): a
  `gen_tcp` socket in every way, except that the first time `:ssl` asks for data, what was
  read ahead is in its mailbox first, as though the socket had just delivered it.

  Rather than putting the byte back on the socket, which `gen_tcp` can do only on the
  inet driver (`unrecv`): on `inet_backend: :socket` that refused every handshake. This
  works on either, through `gen_tcp` and `:inet`'s documented calls.
  """

  # `send/2` below is the transport's, so `Kernel.send/2` is named in full.
  import Kernel, except: [send: 2]

  @table __MODULE__

  @doc """
  Make the table what was read ahead waits in, owned by the caller: the control listener,
  which outlives every handshake on its connections.
  """
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc """
  `:ssl.handshake/3` on `socket`, a passive `gen_tcp` socket from which `read` has been
  read and nothing else. `read` is given to TLS ahead of the rest.
  """
  @spec handshake(:gen_tcp.socket(), binary(), keyword(), timeout()) ::
          {:ok, :ssl.sslsocket()} | {:error, term()}
  def handshake(socket, read, options, timeout) do
    true = :ets.insert(@table, {socket, read})

    try do
      :ssl.handshake(socket, [cb_info: cb_info()] ++ options, timeout)
    after
      :ets.delete(@table, socket)
    end
  end

  # `gen_tcp`'s own tags, so what the socket delivers reaches `:ssl` as it always would.
  defp cb_info, do: {__MODULE__, :tcp, :tcp_closed, :tcp_error, :tcp_passive}

  # -- the transport ----------------------------------------------------------
  #
  # Called by `:ssl` in its connection process, which owns the socket by then. It
  # activates the socket when it wants the next record; the first time, what was read
  # ahead goes to its own mailbox before the socket is activated, so it is there before
  # anything the socket delivers.

  @doc false
  def setopts(socket, options) do
    if active?(options) do
      case :ets.take(@table, socket) do
        [{^socket, read}] -> Kernel.send(self(), {:tcp, socket, read})
        [] -> :ok
      end
    end

    :inet.setopts(socket, options)
  end

  defp active?(options) do
    case List.keyfind(options, :active, 0) do
      {:active, false} -> false
      {:active, _once_true_or_count} -> true
      nil -> false
    end
  end

  @doc false
  def send(socket, data), do: :gen_tcp.send(socket, data)
  @doc false
  def recv(socket, length), do: :gen_tcp.recv(socket, length)
  @doc false
  def recv(socket, length, timeout), do: :gen_tcp.recv(socket, length, timeout)
  @doc false
  def controlling_process(socket, pid), do: :gen_tcp.controlling_process(socket, pid)
  @doc false
  def getopts(socket, options), do: :inet.getopts(socket, options)
  @doc false
  def getstat(socket, options), do: :inet.getstat(socket, options)
  @doc false
  def peername(socket), do: :inet.peername(socket)
  @doc false
  def sockname(socket), do: :inet.sockname(socket)
  @doc false
  def port(socket), do: :inet.port(socket)
  @doc false
  def shutdown(socket, how), do: :gen_tcp.shutdown(socket, how)
  @doc false
  def close(socket), do: :gen_tcp.close(socket)
end
