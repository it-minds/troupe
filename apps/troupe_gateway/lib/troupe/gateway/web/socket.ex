defmodule Troupe.Gateway.Web.Socket do
  @moduledoc """
  One WebSocket, relaying frames to a `Gateway.Connection` and back.

  Two processes rather than one, because they cannot be the same: `WebSock` callbacks
  own the frames and must return them, and a connection is a `GenServer` that answers
  calls — `tool.invoke` among them — while frames are arriving. Trying to be both would
  mean a connection that could not be called during a read.

  So this process owns the socket and nothing else. Frames in become
  `{:transport_data, text}`; writes come back as `{:transport_out, iodata}` and are
  pushed. Neither side ever waits on the other, which is the same rule `Gateway.Writer`
  exists to keep on the TCP side.

  The two processes die together: a browser that closes takes the connection with it,
  and a connection that stops closes the socket.
  """

  @behaviour WebSock

  alias Troupe.Gateway.Connections

  require Logger

  @impl WebSock
  def init(opts) do
    attach = [
      transport: {:relay, self()},
      endpoint: Keyword.fetch!(opts, :endpoint),
      bearer: Keyword.get(opts, :bearer)
    ]

    case Connections.attach(attach) do
      {:ok, connection} ->
        monitor = Process.monitor(connection)
        send(connection, :socket_ready)
        {:ok, %{connection: connection, monitor: monitor}}

      {:error, reason} ->
        Logger.warning("troupe: refusing a websocket: #{inspect(reason)}")
        {:stop, :normal, %{connection: nil, monitor: nil}}
    end
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    # A frame is a whole message and a line is a whole message, and the connection knows
    # only about lines. The newline goes on here and comes off again in `handle_info`,
    # so the two framings meet in this module and nowhere else.
    send(state.connection, {:transport_data, text <> "\n"})
    {:ok, state}
  end

  # Binary frames are not part of the protocol. Refused rather than ignored: a client
  # sending them has misunderstood something, and silence would let it go on doing so.
  def handle_in({_data, [opcode: _other]}, state) do
    {:stop, :normal, 1003, state}
  end

  @impl WebSock
  def handle_info({:transport_out, iodata}, state) do
    # The connection's writer frames with a trailing newline for NDJSON. A text frame is
    # its own frame, so the newline goes: a client splitting on frames must not find a
    # stray empty one.
    {:push, {:text, iodata |> IO.iodata_to_binary() |> String.trim_trailing("\n")}, state}
  end

  def handle_info(:transport_close, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{connection: connection} = state) when is_pid(connection) do
    send(connection, {:transport_closed, :normal})
    state
  end

  def terminate(_reason, state), do: state
end
