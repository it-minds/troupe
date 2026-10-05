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
  body}`, the last sent as JSON in two chunks.
  """

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
    with {:ok, raw} <- read_request(socket, "") do
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

  defp stream("/v1/messages", n, answer) do
    {block, delta, stop_reason} =
      case answer do
        {:text, text} ->
          {%{"type" => "text", "text" => ""}, %{"type" => "text_delta", "text" => text},
           "end_turn"}

        {:tool, name, input} ->
          {%{"type" => "tool_use", "id" => "toolu_#{n}", "name" => name, "input" => %{}},
           %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}
      end

    [
      event("message_start", %{
        "type" => "message_start",
        "message" => %{"usage" => %{"input_tokens" => 100, "output_tokens" => 1}}
      }),
      event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => block
      }),
      event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => delta
      }),
      event("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => %{"output_tokens" => 10}
      }),
      event("message_stop", %{"type" => "message_stop"})
    ]
  end

  defp stream("/v1/chat/completions", n, answer) do
    {delta, finish} =
      case answer do
        {:text, text} ->
          {%{"role" => "assistant", "content" => text}, "stop"}

        {:tool, name, input} ->
          call = %{
            "index" => 0,
            "id" => "call_#{n}",
            "type" => "function",
            "function" => %{"name" => name, "arguments" => Jason.encode!(input)}
          }

          {%{"role" => "assistant", "tool_calls" => [call]}, "tool_calls"}
      end

    [
      data(%{"choices" => [%{"delta" => delta}]}),
      data(%{
        "choices" => [%{"delta" => %{}, "finish_reason" => finish}],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10}
      }),
      "data: [DONE]\n\n"
    ]
  end

  defp event(name, data), do: ["event: ", name, "\ndata: ", Jason.encode!(data), "\n\n"]
  defp data(data), do: ["data: ", Jason.encode!(data), "\n\n"]
end
