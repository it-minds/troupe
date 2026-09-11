defmodule Troupe.Protocol.Client.Transport do
  @moduledoc """
  How a client reaches a server: a socket, or a WebSocket.

  Two, because the protocol says so. Locally a client opens a Unix socket or loopback
  TCP and speaks newline-delimited JSON. A worker pod is on the other side of an
  Ingress, so a client reaches it at `wss://<host>/v1/socket` with one JSON-RPC message
  per text frame. **The messages are identical**; only the framing differs, and this is
  where the difference stops.

  The shape is deliberately message-driven rather than blocking. Both transports deliver
  into the owning process's mailbox, `handle/2` turns whatever arrived into a list of
  complete protocol messages, and the client's handshake and its steady state use the
  same function. A transport that had one path for `init` and another for `handle_info`
  would be two implementations of the hard part.
  """

  alias Troupe.Protocol.JSONRPC

  @type t ::
          {:tcp, :gen_tcp.socket()}
          | {:ws, Mint.HTTP.t(), Mint.Types.request_ref(), Mint.WebSocket.t()}

  @typedoc """
  What a transport made of one mailbox message.

  A close carries whatever arrived with it. A server that refuses a handshake writes the
  refusal and then closes, and both can land in one read: discarding the bytes because
  the connection is going would turn every refusal into `:closed`, which tells the caller
  nothing about why.
  """
  @type outcome ::
          {:ok, t(), [binary()]}
          | {:closed, t() | nil, term(), [binary()]}
          | :unknown

  @doc """
  Connect, and complete any transport-level handshake.

  `:url` selects the WebSocket transport; `:address` and `:port` select the socket one.
  """
  @spec connect(keyword(), timeout()) :: {:ok, t()} | {:error, term()}
  def connect(opts, timeout) do
    case Keyword.get(opts, :url) do
      nil -> tcp_connect(opts, timeout)
      url -> ws_connect(url, opts, timeout)
    end
  end

  @doc "Write one protocol message."
  @spec send(t(), JSONRPC.t()) :: {:ok, t()} | {:error, term()}
  def send({:tcp, socket} = transport, message) do
    case :gen_tcp.send(socket, [JSONRPC.encode(message), ?\n]) do
      :ok -> {:ok, transport}
      {:error, reason} -> {:error, reason}
    end
  end

  def send({:ws, conn, ref, websocket}, message) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, {:text, JSONRPC.encode(message)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, {:ws, conn, ref, websocket}}
    else
      {:error, _conn_or_websocket, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ask for the next read.

  A no-op on the WebSocket: Mint in active mode keeps delivering, and there is nothing
  to re-arm.
  """
  @spec activate(t()) :: :ok
  def activate({:tcp, socket}), do: with({:error, _reason} <- :inet.setopts(socket, active: :once), do: :ok)
  def activate({:ws, _conn, _ref, _websocket}), do: :ok

  @doc """
  Turn one mailbox message into whatever protocol bytes it carried.

  `:unknown` for a message that is not this transport's, so the caller can go on
  handling its own.

  Chunks come back as **newline-terminated** bytes whichever transport produced them. A
  socket already delivers them that way and a frame does not, so a frame gains one here:
  the alternative is for every caller to know which transport it has before it can
  buffer, which is exactly the knowledge this module exists to absorb.
  """
  @spec handle(t(), term()) :: outcome()
  def handle({:tcp, socket} = transport, {:tcp, socket, data}), do: {:ok, transport, [data]}

  def handle({:tcp, socket} = transport, {:tcp_closed, socket}),
    do: {:closed, transport, :closed, []}

  def handle({:tcp, socket} = transport, {:tcp_error, socket, reason}),
    do: {:closed, transport, reason, []}

  def handle({:ws, conn, ref, websocket} = transport, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        collect(conn, ref, websocket, responses)

      {:error, conn, reason, responses} ->
        case collect(conn, ref, websocket, responses) do
          {:ok, transport, texts} -> {:closed, transport, reason, texts}
          {:closed, transport, _other, texts} -> {:closed, transport, reason, texts}
        end

      :unknown ->
        _ = transport
        :unknown
    end
  end

  def handle(_transport, _message), do: :unknown

  @doc "Close, tolerating a transport that has already gone."
  @spec close(t()) :: :ok
  def close({:tcp, socket}), do: :gen_tcp.close(socket)

  def close({:ws, conn, ref, websocket}) do
    with {:ok, _websocket, data} <- Mint.WebSocket.encode(websocket, :close),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      Mint.HTTP.close(conn)
    else
      _other -> Mint.HTTP.close(conn)
    end

    :ok
  end

  # -- sockets ----------------------------------------------------------------

  defp tcp_connect(opts, timeout) do
    address = Keyword.fetch!(opts, :address)
    port = Keyword.get(opts, :port, 0)
    connect_opts = [:binary, active: :once, packet: :raw, send_timeout: 10_000]

    with {:ok, socket} <- :gen_tcp.connect(address, port, connect_opts, timeout) do
      {:ok, {:tcp, socket}}
    end
  end

  # -- websockets -------------------------------------------------------------

  defp ws_connect(url, opts, timeout) do
    with {:ok, target} <- parse(url),
         {:ok, conn} <-
           Mint.HTTP.connect(target.http_scheme, target.host, target.port,
             protocols: [:http1],
             mode: :active,
             transport_opts: [timeout: timeout]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, headers(opts)) do
      await_upgrade(conn, ref, deadline(timeout))
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  # The token goes in the header here, which is what the protocol says and what a
  # reverse proxy expects. A client with no control over its headers can still put it in
  # `auth.token` on `initialize`, and the server takes either.
  defp headers(opts) do
    case Keyword.get(opts, :token) do
      nil -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end

  defp await_upgrade(conn, ref, deadline, status \\ nil, resp_headers \\ []) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mint.HTTP.close(conn)
      {:error, :timeout}
    else
      receive do
        message ->
          case Mint.WebSocket.stream(conn, message) do
            {:ok, conn, responses} ->
              apply_upgrade(conn, ref, deadline, status, resp_headers, responses)

            {:error, conn, reason, _responses} ->
              Mint.HTTP.close(conn)
              {:error, reason}

            :unknown ->
              await_upgrade(conn, ref, deadline, status, resp_headers)
          end
      after
        remaining ->
          Mint.HTTP.close(conn)
          {:error, :timeout}
      end
    end
  end

  defp apply_upgrade(conn, ref, deadline, status, resp_headers, responses) do
    Enum.reduce(responses, {status, resp_headers, nil}, fn
      {:status, ^ref, value}, {_status, headers, done} -> {value, headers, done}
      {:headers, ^ref, value}, {status, _headers, done} -> {status, value, done}
      {:done, ^ref}, {status, headers, _done} -> {status, headers, :done}
      _response, acc -> acc
    end)
    |> case do
      {status, headers, :done} when is_integer(status) ->
        finish_upgrade(conn, ref, status, headers)

      {status, headers, nil} ->
        await_upgrade(conn, ref, deadline, status, headers)
    end
  end

  defp finish_upgrade(conn, ref, status, headers) do
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        {:ok, {:ws, conn, ref, websocket}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, {:upgrade_refused, status, reason}}
    end
  end

  # A server's close frame is a closed transport, and a ping must be answered or the
  # server will eventually decide the client is gone.
  defp collect(conn, ref, websocket, responses) do
    Enum.reduce_while(responses, {:ok, {:ws, conn, ref, websocket}, []}, fn
      {:data, ^ref, data}, {:ok, {:ws, conn, ref, websocket}, texts} ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, frames} ->
            fold_frames({:ws, conn, ref, websocket}, frames, texts)

          {:error, websocket, reason} ->
            {:halt, {:closed, {:ws, conn, ref, websocket}, reason, texts}}
        end

      {:done, ^ref}, {:ok, transport, texts} ->
        {:halt, {:closed, transport, :closed, texts}}

      _response, acc ->
        {:cont, acc}
    end)
  end

  # The close frame ends the reduction but keeps what came before it in the same batch,
  # which on a refused handshake is the refusal itself.
  defp fold_frames(transport, frames, texts) do
    Enum.reduce_while(frames, {:cont, {:ok, transport, texts}}, fn
      {:text, text}, {:cont, {:ok, transport, texts}} ->
        {:cont, {:cont, {:ok, transport, texts ++ [text <> "\n"]}}}

      {:ping, payload}, {:cont, {:ok, transport, texts}} ->
        {:cont, {:cont, {:ok, pong(transport, payload), texts}}}

      {:close, _code, _reason}, {:cont, {:ok, transport, texts}} ->
        {:halt, {:halt, {:closed, transport, :closed, texts}}}

      _frame, acc ->
        {:cont, acc}
    end)
  end

  defp pong({:ws, conn, ref, websocket} = transport, payload) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, {:pong, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ws, conn, ref, websocket}
    else
      _other -> transport
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        {:ok,
         %{
           ws_scheme: String.to_existing_atom(scheme),
           http_scheme: if(scheme == "wss", do: :https, else: :http),
           host: host,
           port: port || if(scheme == "wss", do: 443, else: 80),
           path: path_of(uri)
         }}

      _other ->
        {:error, {:bad_url, url}}
    end
  end

  defp path_of(%URI{path: nil}), do: "/v1/socket"
  defp path_of(%URI{path: path, query: nil}), do: path
  defp path_of(%URI{path: path, query: query}), do: path <> "?" <> query
end
