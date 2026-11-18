defmodule Troupe.Test.LoopbackHTTP do
  @moduledoc """
  The HTTP/1.1 the stand-in servers on a loopback port speak: one request read off a
  socket, its headers, an answer, and the frames of an event stream.

  Compiled with the core's test support; the fakes written as scripts so another suite can
  `Code.require_file` them require this file first when it is not already loaded.
  """

  @doc "One whole request off `socket`: the head, and as much body as its `content-length` says."
  @spec read_request(:gen_tcp.socket()) :: {:ok, binary()} | :error
  def read_request(socket), do: read_request(socket, "")

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: {:ok, acc}, else: read_request(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= content_length(head)
      _ -> false
    end
  end

  defp content_length(head),
    do: head |> headers() |> Map.get("content-length", "0") |> String.to_integer()

  @doc "Every header of a request's head by its lower-case name; a name sent twice keeps the last."
  @spec headers(binary()) :: %{String.t() => String.t()}
  def headers(head) do
    head
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{String.downcase(name), String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc "A whole answer that closes the connection after it."
  @spec respond(pos_integer(), String.t(), iodata(), [{String.t(), String.t()}]) :: iodata()
  def respond(status, type, body, headers \\ []) do
    [
      "HTTP/1.1 #{status} X\r\n",
      "content-type: #{type}\r\n",
      Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "content-length: #{IO.iodata_length(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  @doc "A named event of an event stream, its data as JSON."
  @spec event(String.t(), term()) :: iodata()
  def event(name, data), do: ["event: ", name, "\ndata: ", Jason.encode!(data), "\n\n"]

  @doc "An unnamed event of an event stream, its data as JSON."
  @spec data(term()) :: iodata()
  def data(data), do: ["data: ", Jason.encode!(data), "\n\n"]
end
