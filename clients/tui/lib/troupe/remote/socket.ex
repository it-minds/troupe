defmodule Troupe.Remote.Socket do
  @moduledoc """
  One WebSocket, owned by one process.

  The HTTP upgrade runs synchronously (Mint in passive mode) so a connection
  either exists or failed with a reason worth showing; after that the socket is
  switched to active mode and every frame arrives as a message to the owner,
  which is what lets the plane and worker connections be ordinary GenServers.

  Only text frames carry protocol; pings are answered here and closes are
  reported so the owner can reconnect.
  """

  alias Troupe.Remote.TLS

  @enforce_keys [:conn, :ref, :websocket]
  defstruct [:conn, :ref, :websocket]

  @type t :: %__MODULE__{}
  @type frame :: {:text, String.t()} | {:close, integer() | nil, String.t() | nil}

  @connect_timeout 15_000

  @doc """
  Connects and upgrades. `headers` are sent on the upgrade request — this is
  where the bearer token goes.
  """
  @spec connect(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, t()} | {:error, term()}
  def connect(url, headers \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @connect_timeout)

    with {:ok, %URI{} = uri, http_scheme, ws_scheme} <- parse(url),
         {:ok, conn} <- http_connect(http_scheme, uri, timeout),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path(uri), headers),
         {:ok, conn, status, resp_headers} <- await_upgrade(conn, ref, timeout),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, resp_headers),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :active) do
      {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}}
    else
      {:error, _conn, reason} -> {:error, error_reason(reason)}
      {:error, reason} -> {:error, error_reason(reason)}
    end
  end

  @doc "Sends one text frame."
  @spec send_text(t(), iodata()) :: {:ok, t()} | {:error, term()}
  def send_text(%__MODULE__{} = socket, text) do
    # Mint takes a binary frame payload, and every caller here builds iodata.
    with {:ok, websocket, data} <-
           Mint.WebSocket.encode(socket.websocket, {:text, IO.iodata_to_binary(text)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(socket.conn, socket.ref, data) do
      {:ok, %{socket | conn: conn, websocket: websocket}}
    else
      {:error, _conn_or_websocket, reason} -> {:error, error_reason(reason)}
      {:error, reason} -> {:error, error_reason(reason)}
    end
  end

  @doc """
  Feeds one process message to the socket. Returns the frames it carried, or
  `:unknown` when the message belonged to something else.
  """
  @spec stream(t(), term()) :: {:ok, t(), [frame()]} | {:error, term()} | :unknown
  def stream(%__MODULE__{} = socket, message) do
    case Mint.WebSocket.stream(socket.conn, message) do
      {:ok, conn, responses} ->
        decode_responses(%{socket | conn: conn}, responses, [])

      {:error, conn, reason, _responses} ->
        _ = Mint.HTTP.close(conn)
        {:error, error_reason(reason)}

      :unknown ->
        :unknown
    end
  end

  @doc "Closes the socket, best effort."
  @spec close(t() | nil) :: :ok
  def close(%__MODULE__{} = socket) do
    case Mint.WebSocket.encode(socket.websocket, :close) do
      {:ok, _websocket, data} ->
        _ = Mint.WebSocket.stream_request_body(socket.conn, socket.ref, data)
        _ = Mint.HTTP.close(socket.conn)
        :ok

      _ ->
        _ = Mint.HTTP.close(socket.conn)
        :ok
    end
  end

  def close(_other), do: :ok

  ## Internals

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} = uri when is_binary(host) -> {:ok, uri, :https, :wss}
      %URI{scheme: "ws", host: host} = uri when is_binary(host) -> {:ok, uri, :http, :ws}
      %URI{scheme: "https", host: host} = uri when is_binary(host) -> {:ok, uri, :https, :wss}
      %URI{scheme: "http", host: host} = uri when is_binary(host) -> {:ok, uri, :http, :ws}
      other -> {:error, {:bad_url, other}}
    end
  end

  defp http_connect(:https, %URI{host: host} = uri, timeout) do
    Mint.HTTP.connect(:https, host, port(uri, 443),
      protocols: [:http1],
      mode: :passive,
      timeout: timeout,
      transport_opts: TLS.opts(host)
    )
  end

  defp http_connect(:http, %URI{host: host} = uri, timeout) do
    Mint.HTTP.connect(:http, host, port(uri, 80),
      protocols: [:http1],
      mode: :passive,
      timeout: timeout
    )
  end

  defp port(%URI{port: port}, _default) when is_integer(port), do: port
  defp port(_uri, default), do: default

  defp path(%URI{path: path, query: query}) do
    base = if path in [nil, ""], do: "/", else: path
    if query, do: base <> "?" <> query, else: base
  end

  # The upgrade response is read synchronously; anything but a 101 comes back
  # as the status the server gave, which is what tells a bad token from a bad URL.
  defp await_upgrade(conn, ref, timeout), do: await_upgrade(conn, ref, timeout, nil, [])

  defp await_upgrade(conn, ref, timeout, status, headers) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        case reduce_upgrade(responses, ref, status, headers) do
          {:done, status, headers} -> {:ok, conn, status, headers}
          {:cont, status, headers} -> await_upgrade(conn, ref, timeout, status, headers)
          {:error, reason} -> {:error, reason}
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  defp reduce_upgrade([], _ref, status, headers), do: {:cont, status, headers}

  defp reduce_upgrade([{:status, ref, status} | rest], ref, _status, headers),
    do: reduce_upgrade(rest, ref, status, headers)

  defp reduce_upgrade([{:headers, ref, headers} | rest], ref, status, _headers),
    do: reduce_upgrade(rest, ref, status, headers)

  defp reduce_upgrade([{:done, ref} | _rest], ref, status, headers),
    do: {:done, status, headers}

  defp reduce_upgrade([{:error, ref, reason} | _rest], ref, _status, _headers),
    do: {:error, reason}

  defp reduce_upgrade([_other | rest], ref, status, headers),
    do: reduce_upgrade(rest, ref, status, headers)

  defp decode_responses(socket, [], frames), do: {:ok, socket, Enum.reverse(frames)}

  defp decode_responses(%{ref: ref} = socket, [{:data, ref, data} | rest], frames) do
    case Mint.WebSocket.decode(socket.websocket, data) do
      {:ok, websocket, decoded} ->
        {socket, kept} = Enum.reduce(decoded, {%{socket | websocket: websocket}, frames}, &keep/2)
        decode_responses(socket, rest, kept)

      {:error, _websocket, reason} ->
        {:error, error_reason(reason)}
    end
  end

  defp decode_responses(%{ref: ref} = socket, [{:done, ref} | rest], frames),
    do: decode_responses(socket, rest, [{:close, nil, "server closed"} | frames])

  defp decode_responses(%{ref: ref}, [{:error, ref, reason} | _rest], _frames),
    do: {:error, error_reason(reason)}

  defp decode_responses(socket, [_other | rest], frames),
    do: decode_responses(socket, rest, frames)

  # Pings are answered here: a stalled pong is a dropped connection on most
  # proxies, and nothing above this module needs to know they happened.
  defp keep({:ping, payload}, {socket, frames}) do
    case pong(socket, payload) do
      {:ok, socket} -> {socket, frames}
      {:error, _reason} -> {socket, frames}
    end
  end

  defp keep({:text, text}, {socket, frames}), do: {socket, [{:text, text} | frames]}

  defp keep({:close, code, reason}, {socket, frames}),
    do: {socket, [{:close, code, reason} | frames]}

  defp keep(_frame, acc), do: acc

  defp pong(socket, payload) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(socket.websocket, {:pong, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(socket.conn, socket.ref, data) do
      {:ok, %{socket | conn: conn, websocket: websocket}}
    else
      {:error, _conn_or_websocket, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_reason(%Mint.TransportError{reason: reason}), do: reason
  defp error_reason(%Mint.HTTPError{reason: reason}), do: reason

  defp error_reason(%Mint.WebSocket.UpgradeFailureError{status_code: status}),
    do: {:upgrade, status}

  defp error_reason(reason), do: reason
end
