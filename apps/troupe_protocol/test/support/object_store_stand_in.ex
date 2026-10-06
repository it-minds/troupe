defmodule Troupe.ObjectStoreStandIn do
  @moduledoc """
  An S3 that gives the answers a test tells it to, over real HTTP.

  For what MinIO cannot be made to answer on cue: a batch delete failed with a 503, a
  connection dropped before the answer, a store with no batch delete at all. What a real
  store does is `Troupe.ObjectStoreCase`'s to show.

  `answer` is called with each request, `%{method: "GET", path:, query: %{}, body:}`, and
  gives back `{status, body}`, or `:hang_up` to close the connection without answering.
  Every request is kept, oldest first, for `requests/1`.
  """

  use GenServer

  alias Troupe.ObjectStore

  @spec start_link((map() -> {pos_integer(), binary()} | :hang_up)) :: GenServer.on_start()
  def start_link(answer), do: GenServer.start_link(__MODULE__, answer)

  @doc "A store that points at it."
  @spec store(GenServer.server()) :: ObjectStore.t()
  def store(server) do
    %ObjectStore{
      endpoint: "http://127.0.0.1:#{GenServer.call(server, :port)}",
      bucket: "stand-in",
      access_key_id: "stand-in",
      secret_access_key: "stand-in"
    }
  end

  @doc "Every request it was sent, oldest first."
  @spec requests(GenServer.server()) :: [map()]
  def requests(server), do: GenServer.call(server, :requests)

  @doc "These versions, as one page of `GET ?versions`."
  @spec listing([%{key: String.t(), version_id: String.t()}]) :: binary()
  def listing(versions) do
    entries =
      Enum.map(versions, fn %{key: key, version_id: version} ->
        "<Version><Key>#{key}</Key><VersionId>#{version}</VersionId></Version>"
      end)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      "<ListVersionsResult><IsTruncated>false</IsTruncated>",
      entries,
      "</ListVersionsResult>"
    ])
  end

  @impl GenServer
  def init(answer) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = self()
    spawn_link(fn -> accept(listen, server, answer) end)
    {:ok, %{listen: listen, port: port, requests: []}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  @impl GenServer
  def handle_cast({:request, request}, state),
    do: {:noreply, %{state | requests: [request | state.requests]}}

  defp accept(listen, server, answer) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> receive(do: (:go -> serve(socket, server, answer))) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, server, answer)

      {:error, _closed} ->
        :ok
    end
  end

  # One request a connection: every answer closes it, so nothing is read past a body.
  defp serve(socket, server, answer) do
    request = read(socket)
    GenServer.cast(server, {:request, request})

    case answer.(request) do
      :hang_up ->
        :ok

      {status, body} ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} Stand-in\r\n",
          "content-type: application/xml\r\n",
          "content-length: #{byte_size(body)}\r\n",
          "connection: close\r\n\r\n",
          body
        ])
    end

    :gen_tcp.close(socket)
  end

  defp read(socket) do
    :ok = :inet.setopts(socket, packet: :http_bin)

    {:ok, {:http_request, method, {:abs_path, target}, _version}} =
      :gen_tcp.recv(socket, 0, 5_000)

    headers = read_headers(socket, %{})

    :ok = :inet.setopts(socket, packet: :raw)

    body =
      case String.to_integer(Map.get(headers, "content-length", "0")) do
        0 -> ""
        length -> socket |> :gen_tcp.recv(length, 5_000) |> elem(1)
      end

    [path | query] = String.split(target, "?", parts: 2)

    %{
      method: method |> to_string() |> String.upcase(),
      path: path,
      query: URI.decode_query(List.first(query) || ""),
      body: body
    }
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, Map.put(acc, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        acc
    end
  end
end
