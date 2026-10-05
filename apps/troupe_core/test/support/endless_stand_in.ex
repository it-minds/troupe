defmodule Troupe.Test.EndlessStandIn do
  @moduledoc """
  A model provider on a loopback port whose reply never ends (D69, Decision 788): it
  streams a text delta every `every_ms` for as long as the connection stays open, and
  tells the test when the client has closed it. Only a request that is stopped ends.

  Two wire shapes on one port, as `Troupe.Test.PromptCacheStandIn` has. `POST
  /v1/messages` is Anthropic's, whose `message_start` says what the prompt used, so a
  call stopped part-way has reported its input. `POST /v1/chat/completions` is an
  OpenAI-compatible server's, which says its usage only in the last chunk, so a call
  stopped part-way has reported nothing.

  The test process gets `{:endless_stand_in, :request, path}` when a request arrives and
  `{:endless_stand_in, :closed, deltas}` when its client has gone, with how many deltas
  it was sent by then.
  """

  # What Anthropic's `message_start` reports: the prompt's figures, and one output token.
  @usage %{
    "input_tokens" => 2_000,
    "cache_read_input_tokens" => 500,
    "cache_creation_input_tokens" => 0,
    "output_tokens" => 1
  }

  @doc "Start one. Options: `test` (the caller), `every_ms` (default 100)."
  @spec start(keyword()) :: map()
  def start(opts \\ []) do
    test = Keyword.get(opts, :test, self())
    every = Keyword.get(opts, :every_ms, 100)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn(fn -> accept(listener, test, every) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    %{base_url: "http://127.0.0.1:#{port}", listener: listener}
  end

  @spec stop(map()) :: :ok
  def stop(%{listener: listener}), do: :gen_tcp.close(listener)

  @doc "The usage an Anthropic-shaped reply reports before its first delta."
  @spec usage() :: map()
  def usage, do: @usage

  defp accept(listener, test, every) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, test, every) end)
        accept(listener, test, every)

      {:error, _closed} ->
        :ok
    end
  end

  # A model call is answered for ever. Anything else, the model list a session's catalog
  # refresh asks for among them, is not found.
  defp serve(socket, test, every) do
    with {:ok, raw} <- read_request(socket, "") do
      case raw |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ") do
        ["POST", path | _] when path in ["/v1/messages", "/v1/chat/completions"] ->
          send(test, {:endless_stand_in, :request, path})

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
              opening(path)
            ])

          trickle(socket, path, every, test, 0)

        _other ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

          :gen_tcp.close(socket)
      end
    end
  end

  # The wait between deltas is a read, so a client that closes is seen at once rather than
  # at the next write that fails.
  defp trickle(socket, path, every, test, sent) do
    case :gen_tcp.recv(socket, 0, every) do
      {:error, :timeout} ->
        case :gen_tcp.send(socket, delta(path)) do
          :ok -> trickle(socket, path, every, test, sent + 1)
          {:error, _reason} -> closed(socket, test, sent)
        end

      {:ok, _more} ->
        trickle(socket, path, every, test, sent)

      {:error, _closed} ->
        closed(socket, test, sent)
    end
  end

  defp closed(socket, test, sent) do
    :gen_tcp.close(socket)
    send(test, {:endless_stand_in, :closed, sent})
  end

  defp opening("/v1/messages") do
    [
      event("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_endless",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "usage" => @usage
        }
      }),
      event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      })
    ]
  end

  defp opening(_chat), do: []

  defp delta("/v1/messages") do
    event("content_block_delta", %{
      "type" => "content_block_delta",
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => "and more "}
    })
  end

  defp delta(_chat) do
    data(%{
      "id" => "chatcmpl-endless",
      "object" => "chat.completion.chunk",
      "choices" => [%{"index" => 0, "delta" => %{"content" => "and more "}}]
    })
  end

  defp event(name, payload), do: ["event: ", name, "\n", data(payload)]
  defp data(payload), do: ["data: ", Jason.encode!(payload), "\n\n"]

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: {:ok, acc}, else: read_request(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= content_length(head)
      _ -> false
    end
  end

  defp content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ":", parts: 2) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end
end
