defmodule Troupe.Test.ErrorStandIn do
  @moduledoc """
  A model provider on a loopback port that answers as the test scripts it, an error among
  the answers (#436, Decision 791). An error goes out as a real provider's does: a status,
  a JSON body and no event stream, on a real socket, where Req hands its body to the
  adapter's `into` function as it does a stream's. `Troupe.Test.FakeTransport` stands in
  for that socket in the adapters' own tests; this is the socket.

  Two wire shapes on one port, as `Troupe.Test.PromptCacheStandIn` has: `POST
  /v1/messages`, Anthropic's, and `POST /v1/chat/completions`, an OpenAI-compatible
  server's. Every request reaches the test process as `{:error_stand_in, n, path, body}`;
  what it is answered with is the test's `script`, a function of the call's number and its
  decoded body returning `{:text, text}`, `{:tool, name, input}` or `{:status, status,
  body}`, the last sent as JSON in two chunks. On Anthropic's path it may also return
  `{:thinking_tool, signature, name, input}`, a tool call after a thinking block with
  nothing in it but its signature, as the newest models stream one when no summary was
  asked for, and `{:stream_error, error}`, an `error` event inside a stream that began
  with a 200 (#427, Decision 805).

  On the OpenAI-compatible path `{:priced, answer, cost}` is `answer` with `cost`, in
  dollars, in the stream's usage, as a LiteLLM gateway writes it.
  """

  import Troupe.Test.LoopbackHTTP, only: [event: 2]

  alias Troupe.Test.{LoopbackHTTP, ModelStream}

  @doc "Start one. Options: `script` (required), `test` (the caller)."
  @spec start(keyword()) :: map()
  def start(opts) do
    context = %{test: Keyword.get(opts, :test, self()), script: Keyword.fetch!(opts, :script)}

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    {:ok, counter} = Agent.start(fn -> 0 end)
    context = Map.put(context, :counter, counter)

    acceptor = spawn(fn -> accept(listener, context) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    %{base_url: "http://127.0.0.1:#{port}", listener: listener, counter: counter}
  end

  @spec stop(map()) :: :ok
  def stop(%{listener: listener, counter: counter}) do
    :gen_tcp.close(listener)
    if Process.alive?(counter), do: Agent.stop(counter)
    :ok
  end

  @doc "Every request seen so far, in order, as `{n, path, body}`."
  @spec drain([tuple()]) :: [tuple()]
  def drain(acc \\ []) do
    receive do
      {:error_stand_in, n, path, body} -> drain([{n, path, body} | acc])
    after
      0 -> Enum.sort_by(acc, &elem(&1, 0))
    end
  end

  defp accept(listener, context) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, context) end)
        accept(listener, context)

      {:error, _closed} ->
        :ok
    end
  end

  # A model call is answered as scripted. Anything else, the model list a session's catalog
  # refresh asks for among them, is not found.
  defp serve(socket, context) do
    with {:ok, raw} <- LoopbackHTTP.read_request(socket) do
      case parse(raw) do
        {:ok, path, body} when path in ["/v1/messages", "/v1/chat/completions"] ->
          n = Agent.get_and_update(context.counter, &{&1 + 1, &1 + 1})
          send(context.test, {:error_stand_in, n, path, body})
          :gen_tcp.send(socket, answer(path, n, context.script.(n, body)))

        _other ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )
      end
    end

    :gen_tcp.close(socket)
  end

  defp parse(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [_method, path | _] = head |> String.split("\r\n") |> hd() |> String.split(" ")

    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, path, decoded}
      _ -> {:ok, path, %{}}
    end
  end

  # -- the answers --------------------------------------------------------------

  # An error is JSON in two chunks of a chunked body, so the adapter has to put it back
  # together, as it would a provider's that the network split.
  defp answer(_path, _n, {:status, status, body}) do
    json = Jason.encode!(body)
    half = div(byte_size(json), 2)

    [
      "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n",
      "transfer-encoding: chunked\r\nconnection: close\r\n\r\n",
      chunk(binary_part(json, 0, half)),
      chunk(binary_part(json, half, byte_size(json) - half)),
      "0\r\n\r\n"
    ]
  end

  defp answer(path, n, answer) do
    [
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
      stream(path, n, answer)
    ]
  end

  defp chunk(part), do: [Integer.to_string(byte_size(part), 16), "\r\n", part, "\r\n"]

  defp stream("/v1/messages", n, {:thinking_tool, signature, name, input}) do
    [
      message_start(),
      event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }),
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => signature}
      }),
      event("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_#{n}",
          "name" => name,
          "input" => %{}
        }
      }),
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}
      }),
      event("content_block_stop", %{"type" => "content_block_stop", "index" => 1}),
      message_end("tool_use")
    ]
  end

  defp stream("/v1/messages", _n, {:stream_error, error}) do
    [message_start(), event("error", %{"type" => "error", "error" => error})]
  end

  defp stream("/v1/messages" = path, n, answer),
    do: ModelStream.events(path, n, answer, %{"input_tokens" => 100})

  # A gateway that writes what the call cost into the stream's usage, as LiteLLM does
  # when asked: `cost` in dollars beside the tokens.
  defp stream("/v1/chat/completions" = path, n, {:priced, answer, cost}),
    do: ModelStream.events(path, n, answer, %{"prompt_tokens" => 100, "cost" => cost})

  defp stream("/v1/chat/completions" = path, n, answer),
    do: ModelStream.events(path, n, answer, %{"prompt_tokens" => 100})

  defp message_start do
    event("message_start", %{
      "type" => "message_start",
      "message" => %{"usage" => %{"input_tokens" => 100, "output_tokens" => 1}}
    })
  end

  defp message_end(stop_reason) do
    [
      event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => %{"output_tokens" => 10}
      }),
      event("message_stop", %{"type" => "message_stop"})
    ]
  end
end
