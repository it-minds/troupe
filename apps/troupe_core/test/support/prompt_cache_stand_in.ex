defmodule Troupe.Test.PromptCacheStandIn do
  @moduledoc """
  A model provider on a loopback port that keeps a prompt cache the way the real ones do,
  so a test can see what a request asked to have cached and what it would have been
  billed for (Decision 770).

  Two wire shapes on one port. `POST /v1/messages` is Anthropic's: nothing is cached that
  no block marked with `cache_control`. Each mark writes the prompt up to it — tools,
  then system, then messages — and a later request reads the longest prefix it repeats,
  found by looking back from each of its own marks at most 20 blocks, as Anthropic does.
  `POST /v1/chat/completions` is an OpenAI-compatible server's: every prompt is cached
  without being asked, and a later request reads the longest run of leading messages it
  repeats. With `gateway: :litellm` it is a LiteLLM gateway in front of an Anthropic model
  instead, set to mark the prompt up to the last message: what it writes it reports as
  Anthropic does, in Anthropic's names and in `prompt_tokens_details`, all three input
  figures counted in `prompt_tokens` (D65, Decision 780).

  A token here is four bytes of a block's JSON with its mark taken out. The numbers are
  no model's, but they add up the way a provider's do, which is all the tests read. Every
  request reaches the test process as `{:prompt_cache_stand_in, n, path, body, usage}`;
  what it is answered with is the test's `script`, a function of the call's number and
  its decoded body returning `{:text, text}` or `{:tool, name, input}`.
  """

  @lookback 20

  @doc "Start one. Options: `script` (required), `test` (the caller), `gateway`."
  @spec start(keyword()) :: map()
  def start(opts) do
    context = %{
      test: Keyword.get(opts, :test, self()),
      script: Keyword.fetch!(opts, :script),
      gateway: Keyword.get(opts, :gateway, :openai)
    }

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    {:ok, agent} = Agent.start(fn -> %{calls: 0, cached: MapSet.new()} end)
    context = Map.put(context, :agent, agent)

    acceptor = spawn(fn -> accept(listener, context) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    %{base_url: "http://127.0.0.1:#{port}", listener: listener, agent: agent}
  end

  @spec stop(map()) :: :ok
  def stop(%{listener: listener, agent: agent}) do
    :gen_tcp.close(listener)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  @doc "Every request seen so far, in order, as `{n, path, body, usage}`."
  @spec drain([tuple()]) :: [tuple()]
  def drain(acc \\ []) do
    receive do
      {:prompt_cache_stand_in, n, path, body, usage} -> drain([{n, path, body, usage} | acc])
    after
      0 -> Enum.sort_by(acc, &elem(&1, 0))
    end
  end

  # -- the server ---------------------------------------------------------------

  defp accept(listener, context) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, context) end)
        accept(listener, context)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, context) do
    with {:ok, raw} <- read_request(socket, ""),
         {:ok, path, body} when path in ["/v1/messages", "/v1/chat/completions"] <- parse(raw) do
      {n, usage} = Agent.get_and_update(context.agent, &charge(&1, path, body, context.gateway))
      send(context.test, {:prompt_cache_stand_in, n, path, body, usage})

      answer = context.script.(n, body)

      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
        stream(path, n, answer, usage)
      ])
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
      _ -> :error
    end
  end

  # -- the cache ----------------------------------------------------------------

  defp charge(state, path, body, gateway) do
    n = state.calls + 1
    prefixes = prefixes(positions(path, body), body["model"])

    {usage, cached} =
      if path == "/v1/chat/completions" and gateway == :litellm,
        do: litellm_usage(prefixes, state.cached),
        else: usage(path, prefixes, state.cached)

    {{n, usage}, %{state | calls: n, cached: cached}}
  end

  defp positions("/v1/messages", body) do
    tools = Enum.map(body["tools"] || [], &{"tool", &1})

    system =
      case body["system"] do
        nil -> []
        text when is_binary(text) -> [{"system", %{"type" => "text", "text" => text}}]
        blocks -> Enum.map(blocks, &{"system", &1})
      end

    messages =
      Enum.flat_map(body["messages"] || [], fn message ->
        message["content"] |> blocks() |> Enum.map(&{message["role"], &1})
      end)

    tools ++ system ++ messages
  end

  defp positions("/v1/chat/completions", body) do
    Enum.map(body["tools"] || [], &{"tool", &1}) ++
      Enum.map(body["messages"] || [], &{"message", &1})
  end

  defp blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp blocks(blocks) when is_list(blocks), do: blocks

  # Each position's running hash and running length. A hash covers everything before it
  # too, so two requests share a hash exactly where they share the whole prefix.
  defp prefixes(positions, model) do
    seed = :crypto.hash(:sha256, to_string(model))

    {prefixes, _} =
      Enum.map_reduce(positions, {seed, 0}, fn {kind, block}, {hash, length} ->
        encoded = Jason.encode!([kind, Map.delete(block, "cache_control")])
        hash = :crypto.hash(:sha256, [hash, encoded])
        length = length + max(div(byte_size(encoded), 4), 1)

        {%{hash: hash, length: length, marked?: Map.has_key?(block, "cache_control")},
         {hash, length}}
      end)

    prefixes
  end

  # Anthropic's: read the longest marked prefix a mark can find within the lookback,
  # write from there to the last mark, and bill the rest in full.
  defp usage("/v1/messages", prefixes, cached) do
    at = List.to_tuple(prefixes)
    marks = for {prefix, index} <- Enum.with_index(prefixes), prefix.marked?, do: index

    read = marks |> Enum.map(&found(at, &1, cached)) |> Enum.max(fn -> 0 end)

    written =
      case marks do
        [] -> 0
        _ -> max(elem(at, List.last(marks)).length - read, 0)
      end

    usage = %{
      "input_tokens" => total(prefixes) - read - written,
      "cache_read_input_tokens" => read,
      "cache_creation_input_tokens" => written
    }

    {usage, Enum.reduce(marks, cached, &MapSet.put(&2, elem(at, &1).hash))}
  end

  # An OpenAI-compatible server's: everything is cached, and `prompt_tokens` counts the
  # cached tokens too.
  defp usage("/v1/chat/completions", prefixes, cached) do
    read =
      prefixes
      |> Enum.filter(&MapSet.member?(cached, &1.hash))
      |> Enum.map(& &1.length)
      |> Enum.max(fn -> 0 end)

    usage = %{
      "prompt_tokens" => total(prefixes),
      "prompt_tokens_details" => %{"cached_tokens" => read}
    }

    {usage, Enum.reduce(prefixes, cached, &MapSet.put(&2, &1.hash))}
  end

  # A LiteLLM gateway's, in front of an Anthropic model it marks up to the last message:
  # the longest marked prefix it repeats is read, the rest up to the mark is written, and
  # the last message is fresh input. `prompt_tokens` counts all three, as LiteLLM's does.
  defp litellm_usage(prefixes, cached) do
    marked = Enum.drop(prefixes, -1)

    read =
      marked
      |> Enum.filter(&MapSet.member?(cached, &1.hash))
      |> Enum.map(& &1.length)
      |> Enum.max(fn -> 0 end)

    written = max(total(marked) - read, 0)
    fresh = total(prefixes) - read - written

    usage = %{
      "prompt_tokens" => total(prefixes),
      "prompt_tokens_details" => %{
        "cached_tokens" => read,
        "cache_creation_tokens" => written,
        "text_tokens" => fresh
      },
      "cache_creation_input_tokens" => written,
      "cache_read_input_tokens" => read
    }

    {usage, Enum.reduce(marked, cached, &MapSet.put(&2, &1.hash))}
  end

  # How much one Anthropic mark reads: the longest cached prefix at it or at most 20
  # blocks before it.
  defp found(at, mark, cached) do
    Enum.find_value(mark..max(mark - @lookback, 0)//-1, 0, fn index ->
      prefix = elem(at, index)
      if MapSet.member?(cached, prefix.hash), do: prefix.length
    end)
  end

  defp total([]), do: 0
  defp total(prefixes), do: List.last(prefixes).length

  # -- the answers --------------------------------------------------------------

  defp stream("/v1/messages", n, answer, usage) do
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
        "message" => %{"usage" => Map.put(usage, "output_tokens", 1)}
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

  defp stream("/v1/chat/completions", n, answer, usage) do
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
        "usage" => Map.put(usage, "completion_tokens", 10)
      }),
      "data: [DONE]\n\n"
    ]
  end

  defp event(name, data), do: ["event: ", name, "\ndata: ", Jason.encode!(data), "\n\n"]
  defp data(data), do: ["data: ", Jason.encode!(data), "\n\n"]
end
