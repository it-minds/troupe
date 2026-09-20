defmodule Troupe.LLM.Providers.Anthropic do
  @moduledoc """
  The Anthropic Messages API: native tool use, streamed over SSE.

  Runs inside a task under the calling agent's `Agent.Tasks` supervisor. Retries on
  429 and 5xx with jittered backoff happen here; the agent only ever sees deltas
  followed by exactly one `{:llm_done, ...}` or `{:llm_error, ...}`.
  """

  @behaviour Troupe.LLM.Provider

  alias Troupe.LLM.{
    Delta,
    Gateway,
    Message,
    Provider,
    Reasoning,
    Request,
    SSE,
    Text,
    ToolResult,
    ToolUse
  }

  alias Troupe.LLM.Endpoint
  alias Troupe.LLM.Providers.Anthropic.Collector

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"

  @impl Troupe.LLM.Provider
  def stream(%Request{} = request, reply_to, ref) do
    result =
      Provider.with_retries(
        fn -> attempt(request, reply_to, ref) end,
        request.max_retries
      )

    case result do
      {:ok, response} -> send(reply_to, {:llm_done, ref, response})
      {:error, reason} -> send(reply_to, {:llm_error, ref, reason})
    end

    :ok
  end

  defp attempt(request, reply_to, ref) do
    case api_key(request) do
      nil -> {:error, :missing_api_key}
      key -> post(request, key, reply_to, ref)
    end
  end

  defp post(request, key, reply_to, ref) do
    options = [
      url: Endpoint.build(base_url(request), "/v1/messages"),
      method: :post,
      json: body(request),
      headers: [
        auth_header(request, key),
        {"anthropic-version", @api_version},
        {"accept", "text/event-stream"}
      ],
      receive_timeout: request.timeout_ms,
      # Retries are handled by `Provider.with_retries/2` so that one policy covers
      # both adapters and a retried request re-emits nothing to the agent.
      retry: false,
      # Req threads streaming state through `{req, resp}`; keeping the accumulator in
      # the response's private map means it lives and dies with this one request.
      into: fn {:data, chunk}, {req, resp} ->
        {:cont, {req, handle_chunk(resp, chunk, reply_to, ref)}}
      end
    ]

    case options |> Req.new() |> with_transport(request) |> Req.request() do
      {:ok, %Req.Response{status: 200} = response} ->
        finish(response)

      {:ok, %Req.Response{status: status}} when status in [429] or status >= 500 ->
        {:retry, {:http_status, status}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, describe(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:retry, {:transport, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A test supplies its own transport here rather than a socket, so the request goes
  # through Req's real pipeline while the bytes are scripted.
  defp with_transport(req, %Request{extra: extra}) do
    case Map.get(extra, :req_adapter) do
      nil ->
        req

      {module, config} ->
        %{req | adapter: module} |> Req.Request.put_private(:troupe_fake, config)
    end
  end

  defp handle_chunk(resp, chunk, reply_to, ref) do
    state = resp.private[:troupe] || %{acc: Collector.new(), sse: SSE.new()}
    {events, sse} = SSE.feed(state.sse, chunk)
    sink = %{reply_to: reply_to, ref: ref}

    acc =
      Enum.reduce(events, state.acc, fn event, acc ->
        case SSE.decode(event) do
          {:ok, decoded} -> apply_event(acc, decoded, sink)
          _ -> acc
        end
      end)

    Req.Response.put_private(resp, :troupe, %{acc: acc, sse: sse})
  end

  defp finish(%Req.Response{} = response) do
    case response.private[:troupe] do
      nil ->
        {:error, :no_stream_received}

      %{acc: %Collector{error: error}} when is_binary(error) ->
        {:error, {:api_error, error}}

      %{acc: acc} ->
        # The gateway's headers are read here rather than in the collector because they
        # belong to the HTTP response and not to the event stream: a gateway sends them
        # once, before the first chunk, and the collector never sees them.
        answer = Collector.to_response(acc)
        {:ok, %{answer | gateway: Gateway.from_headers(response.headers)}}
    end
  end

  # -- streaming events -------------------------------------------------------

  defp apply_event(acc, %{"type" => "message_start", "message" => message}, _collector) do
    Collector.merge_usage(acc, message["usage"])
  end

  defp apply_event(acc, %{"type" => "content_block_start"} = event, collector) do
    index = event["index"]

    case event["content_block"] do
      %{"type" => "text"} ->
        Collector.open_text(acc, index)

      %{"type" => "tool_use", "id" => id, "name" => name} ->
        emit(collector, %Delta{kind: :tool_use_start, id: id, name: name})
        Collector.open_tool(acc, index, id, name)

      %{"type" => "thinking"} = block ->
        Collector.open_thinking(acc, index, block["thinking"] || "")

      # Thinking the provider encrypted: nothing to stream, but it goes back verbatim on
      # the next turn all the same.
      %{"type" => "redacted_thinking"} = block ->
        Collector.put_redacted(acc, index, block["data"] || "")

      _ ->
        acc
    end
  end

  defp apply_event(acc, %{"type" => "content_block_delta"} = event, collector) do
    index = event["index"]

    case event["delta"] do
      %{"type" => "text_delta", "text" => text} ->
        emit(collector, Delta.text(text))
        Collector.append_text(acc, index, text)

      %{"type" => "input_json_delta", "partial_json" => fragment} ->
        emit(collector, %Delta{kind: :tool_input, fragment: fragment})
        Collector.append_tool_input(acc, index, fragment)

      # Thinking is shown live under its own kind *and* kept: with thinking enabled,
      # Anthropic rejects a tool-use turn whose thinking blocks are not handed back with
      # the signature it issued for them (Decision 658).
      %{"type" => "thinking_delta", "thinking" => text} ->
        emit(collector, Delta.reasoning(text))
        Collector.append_thinking(acc, index, text)

      %{"type" => "signature_delta", "signature" => signature} ->
        Collector.append_signature(acc, index, signature)

      _ ->
        acc
    end
  end

  defp apply_event(acc, %{"type" => "message_delta"} = event, _collector) do
    # `message_delta` reports running totals for the message, not increments, so each
    # figure it carries replaces the one from `message_start` rather than adding to it.
    acc
    |> Collector.put_stop_reason(stop_reason(get_in(event, ["delta", "stop_reason"])))
    |> Collector.merge_usage(event["usage"])
  end

  defp apply_event(acc, %{"type" => "error", "error" => error}, _collector) do
    Collector.put_error(acc, describe(error))
  end

  defp apply_event(acc, _event, _collector), do: acc

  defp emit(%{reply_to: reply_to, ref: ref}, delta) do
    send(reply_to, {:llm_delta, ref, delta})
  end

  # -- request shaping --------------------------------------------------------

  defp body(%Request{} = request) do
    keep_thinking? = thinking_budget(request.reasoning_effort) != nil

    %{
      model: request.model,
      max_tokens: request.max_tokens,
      stream: true,
      messages: Enum.map(request.messages, &encode_message(&1, keep_thinking?))
    }
    |> maybe_put(:system, request.system)
    |> maybe_put(:temperature, request.temperature)
    |> maybe_put(:tools, encode_tools(request.tools))
    # Anthropic takes one opaque end-user id and nothing else, so the session's owner
    # goes there. Everything else a gateway wants is carried by the OpenAI-compatible
    # adapter, which is what a LiteLLM deployment actually speaks.
    |> maybe_put(:metadata, metadata(request))
    |> put_thinking(request.reasoning_effort)
  end

  # Anthropic takes a thinking budget in tokens where an OpenAI-compatible provider takes
  # an effort level, so a configured effort becomes a budget. The budget has to fit inside
  # `max_tokens`, so enabling thinking raises the output cap along with it rather than
  # failing the request (Decision 658).
  defp put_thinking(body, effort) do
    case thinking_budget(effort) do
      nil ->
        body

      budget ->
        body
        |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
        |> Map.put(:max_tokens, max(body.max_tokens, budget + 4_096))
    end
  end

  defp thinking_budget(effort) when effort in [nil, "none", "off"], do: nil
  defp thinking_budget("minimal"), do: 1_024
  defp thinking_budget("low"), do: 4_096
  defp thinking_budget("medium"), do: 8_192
  defp thinking_budget("high"), do: 16_384
  defp thinking_budget("xhigh"), do: 32_768

  defp thinking_budget(other) when is_binary(other) do
    case Integer.parse(other) do
      {n, ""} when n >= 1_024 -> n
      _ -> nil
    end
  end

  defp metadata(%Request{attribution: %{owner: owner}}) when is_binary(owner) do
    %{user_id: owner}
  end

  defp metadata(%Request{}), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{name: tool.name, description: tool.description, input_schema: tool.schema}
    end)
  end

  defp encode_message(%Message{role: role, content: content}, keep_thinking?) do
    blocks = Enum.reject(content, &drop_reasoning?(&1, keep_thinking?))
    %{role: Atom.to_string(role), content: Enum.map(blocks, &encode_block/1)}
  end

  # Which reasoning may go back out. Another provider's thinking carries no signature
  # Anthropic can verify, and a thinking block is only legal on a request that has
  # thinking enabled — so with thinking off, or for anything that came from an
  # OpenAI-compatible provider, the block is dropped and the rest of the turn goes
  # unchanged.
  defp drop_reasoning?(%Reasoning{provider: :anthropic}, keep_thinking?), do: not keep_thinking?
  defp drop_reasoning?(%Reasoning{}, _keep_thinking?), do: true
  defp drop_reasoning?(_block, _keep_thinking?), do: false

  defp encode_block(%Reasoning{redacted: true, text: data}),
    do: %{type: "redacted_thinking", data: data}

  defp encode_block(%Reasoning{text: text, signature: signature}),
    do: %{type: "thinking", thinking: text, signature: signature}

  defp encode_block(%Text{text: text}), do: %{type: "text", text: text}

  defp encode_block(%ToolUse{id: id, name: name, input: input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp encode_block(%ToolResult{tool_use_id: id, content: content, error?: error?}) do
    %{type: "tool_result", tool_use_id: id, content: content, is_error: error?}
  end

  defp stop_reason("end_turn"), do: :end_turn
  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("stop_sequence"), do: :stop_sequence
  defp stop_reason(_), do: :other

  defp base_url(%Request{base_url: nil}), do: @default_base_url
  defp base_url(%Request{base_url: url}), do: url

  defp api_key(%Request{api_key: key}) when is_binary(key) and key != "", do: key
  defp api_key(_request), do: System.get_env("ANTHROPIC_API_KEY")

  # Anthropic's own scheme is `x-api-key`; a gateway in front of its API usually wants
  # the same token as a bearer, which is what `auth_token` in a config file says.
  defp auth_header(%Request{auth: :bearer}, key), do: {"authorization", "Bearer " <> key}
  defp auth_header(_request, key), do: {"x-api-key", key}

  defp describe(%{"message" => message}), do: message
  defp describe(body) when is_binary(body), do: String.slice(body, 0, 400)
  defp describe(body), do: inspect(body) |> String.slice(0, 400)
end

defmodule Troupe.LLM.Providers.Anthropic.Collector do
  @moduledoc """
  Accumulates a streamed Anthropic response into content blocks.

  Blocks arrive interleaved and indexed, and tool input arrives as JSON fragments, so
  they have to be reassembled in index order before the agent can act on them.
  """

  alias Troupe.LLM.{Reasoning, Response, Text, ToolUse, Usage}

  defstruct blocks: %{}, usage: %Usage{}, stop_reason: :end_turn, error: nil

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec open_text(t(), non_neg_integer()) :: t()
  def open_text(acc, index) do
    %{acc | blocks: Map.put_new(acc.blocks, index, {:text, ""})}
  end

  @spec open_tool(t(), non_neg_integer(), String.t(), String.t()) :: t()
  def open_tool(acc, index, id, name) do
    %{acc | blocks: Map.put(acc.blocks, index, {:tool, id, name, ""})}
  end

  @spec append_text(t(), non_neg_integer(), String.t()) :: t()
  def append_text(acc, index, text) do
    blocks =
      Map.update(acc.blocks, index, {:text, text}, fn
        {:text, existing} -> {:text, existing <> text}
        other -> other
      end)

    %{acc | blocks: blocks}
  end

  @spec open_thinking(t(), non_neg_integer(), String.t()) :: t()
  def open_thinking(acc, index, text) do
    %{acc | blocks: Map.put(acc.blocks, index, {:thinking, text, nil})}
  end

  @spec append_thinking(t(), non_neg_integer(), String.t()) :: t()
  def append_thinking(acc, index, text) do
    blocks =
      Map.update(acc.blocks, index, {:thinking, text, nil}, fn
        {:thinking, existing, signature} -> {:thinking, existing <> text, signature}
        other -> other
      end)

    %{acc | blocks: blocks}
  end

  @spec append_signature(t(), non_neg_integer(), String.t()) :: t()
  def append_signature(acc, index, signature) do
    blocks =
      Map.update(acc.blocks, index, {:thinking, "", signature}, fn
        {:thinking, text, existing} -> {:thinking, text, (existing || "") <> signature}
        other -> other
      end)

    %{acc | blocks: blocks}
  end

  @spec put_redacted(t(), non_neg_integer(), String.t()) :: t()
  def put_redacted(acc, index, data) do
    %{acc | blocks: Map.put(acc.blocks, index, {:redacted, data})}
  end

  @spec append_tool_input(t(), non_neg_integer(), String.t()) :: t()
  def append_tool_input(acc, index, fragment) do
    blocks =
      Map.update(acc.blocks, index, {:tool, nil, nil, fragment}, fn
        {:tool, id, name, existing} -> {:tool, id, name, existing <> fragment}
        other -> other
      end)

    %{acc | blocks: blocks}
  end

  @doc """
  Fold what an event said about usage into the running record.

  Anthropic reports the cache figures beside `input_tokens` rather than inside it, which
  is already the shape `Troupe.LLM.Usage` wants (Decision 657). They arrive on
  `message_start`; `message_delta` carries the final output count and, on some models,
  corrected input counts. Every figure is a running total, so a key that is present
  replaces and a key that is absent leaves what was already counted alone.
  """
  @spec merge_usage(t(), map() | nil) :: t()
  def merge_usage(acc, nil), do: acc

  def merge_usage(acc, reported) when is_map(reported) do
    usage = %Usage{
      input_tokens: count(reported["input_tokens"], acc.usage.input_tokens),
      output_tokens: count(reported["output_tokens"], acc.usage.output_tokens),
      cache_read: count(reported["cache_read_input_tokens"], acc.usage.cache_read),
      cache_write: count(reported["cache_creation_input_tokens"], acc.usage.cache_write)
    }

    %{acc | usage: usage}
  end

  defp count(n, _default) when is_integer(n) and n >= 0, do: n
  defp count(_other, default), do: default

  @spec put_stop_reason(t(), atom()) :: t()
  def put_stop_reason(acc, reason), do: %{acc | stop_reason: reason}

  @spec put_error(t(), String.t()) :: t()
  def put_error(acc, message), do: %{acc | error: message}

  @spec to_response(t()) :: Response.t()
  def to_response(%__MODULE__{} = acc) do
    content =
      acc.blocks
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.flat_map(fn {_index, block} -> materialise(block) end)

    %Response{content: content, stop_reason: acc.stop_reason, usage: acc.usage}
  end

  defp materialise({:text, ""}), do: []
  defp materialise({:text, text}), do: [%Text{text: text}]

  defp materialise({:thinking, text, signature}),
    do: [%Reasoning{provider: :anthropic, text: text, signature: signature}]

  defp materialise({:redacted, data}),
    do: [%Reasoning{provider: :anthropic, text: data, redacted: true}]

  defp materialise({:tool, id, name, raw}) when is_binary(id) and is_binary(name) do
    [%ToolUse{id: id, name: name, input: decode_input(raw)}]
  end

  defp materialise(_block), do: []

  # A tool call whose arguments did not parse still has to reach the agent: it becomes
  # an error tool result the model can see and correct, which is strictly better than
  # dropping the call and leaving the model wondering.
  defp decode_input(""), do: %{}

  defp decode_input(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"__malformed_arguments__" => raw}
    end
  end
end
