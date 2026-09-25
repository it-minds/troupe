defmodule Troupe.LLM.Providers.OpenAI do
  @moduledoc """
  OpenAI-compatible Chat Completions: function calling, streamed over SSE.

  Written against the shape rather than the vendor, so it works unchanged against
  LiteLLM, vLLM, Mistral, Ollama's compatibility endpoint and anything else that
  speaks `/v1/chat/completions` — point `base_url` at it.

  Two shape differences from the Anthropic adapter drive the translation here.
  Function arguments arrive as a JSON *string* rather than an object, so tool calls
  are reassembled from streamed fragments and parsed at the end. And tool results are
  their own `role: "tool"` messages rather than blocks inside a user message, so one
  internal message can expand into several.
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
    ToolUse,
    Usage
  }

  alias Troupe.LLM.Endpoint
  alias Troupe.LLM.Providers.OpenAI.Collector

  @default_base_url "https://api.openai.com"

  @impl Troupe.LLM.Provider
  def stream(%Request{} = request, reply_to, ref) do
    result = Provider.with_retries(fn -> attempt(request, reply_to, ref) end, request.max_retries)

    case result do
      {:ok, response} -> send(reply_to, {:llm_done, ref, response})
      {:error, reason} -> send(reply_to, {:llm_error, ref, reason})
    end

    :ok
  end

  defp attempt(%Request{api_key: {:refused, _why} = refused}, _reply_to, _ref), do: {:error, refused}
  defp attempt(request, reply_to, ref), do: post(request, body(request), reply_to, ref, :first)

  defp post(request, body, reply_to, ref, pass) do
    options = [
      url: Endpoint.build(base_url(request), "/v1/chat/completions"),
      method: :post,
      json: body,
      headers: headers(request),
      receive_timeout: request.timeout_ms,
      retry: false,
      into: fn {:data, chunk}, {req, resp} ->
        {:cont, {req, handle_chunk(resp, chunk, reply_to, ref)}}
      end
    ]

    case options |> Req.new() |> with_transport(request) |> Req.request() do
      {:ok, %Req.Response{status: 200} = response} ->
        finish(response)

      # A rate limit says how long to wait, when it says anything; the retry policy
      # takes the hint (Decision 659).
      {:ok, %Req.Response{status: 429} = response} ->
        {:retry, {:http_status, 429}, Provider.retry_after_ms(response.headers)}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:retry, {:http_status, status}}

      # A reasoning model refuses `max_tokens` and asks for `max_completion_tokens` by
      # name; a plain compatible server knows only the first. Nothing in a model id says
      # which, but the 400 says exactly which — so the request that found out goes again
      # with the other field, once, instead of every user discovering this and
      # configuring it (Decision 658).
      {:ok, %Req.Response{status: 400, body: refused}} ->
        refused(request, body, describe(refused), reply_to, ref, pass)

      {:ok, %Req.Response{status: status, body: refused}} ->
        {:error, {:http_status, status, describe(refused)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:retry, {:transport, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refused(request, body, detail, reply_to, ref, :first) do
    case output_cap_retry(body, detail) do
      nil -> {:error, {:http_status, 400, detail}}
      swapped -> post(request, swapped, reply_to, ref, :second)
    end
  end

  defp refused(_request, _body, detail, _reply_to, _ref, :second),
    do: {:error, {:http_status, 400, detail}}

  @doc false
  @spec output_cap_retry(map(), term()) :: map() | nil
  def output_cap_retry(body, detail) when is_binary(detail) do
    cond do
      String.contains?(detail, "max_completion_tokens") and Map.has_key?(body, :max_tokens) ->
        body |> Map.delete(:max_tokens) |> Map.put(:max_completion_tokens, body.max_tokens)

      String.contains?(detail, "max_tokens") and Map.has_key?(body, :max_completion_tokens) ->
        body
        |> Map.delete(:max_completion_tokens)
        |> Map.put(:max_tokens, body.max_completion_tokens)

      true ->
        nil
    end
  end

  def output_cap_retry(_body, _detail), do: nil

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

  defp headers(request) do
    base = [{"accept", "text/event-stream"}]

    # A local vLLM or Ollama often needs no key at all, so a missing one is not an
    # error here the way it is for a hosted API.
    case api_key(request) do
      nil -> base
      key -> [{"authorization", "Bearer " <> key} | base]
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
          :done -> acc
          :error -> acc
        end
      end)

    Req.Response.put_private(resp, :troupe, %{acc: acc, sse: sse})
  end

  defp finish(%Req.Response{} = response) do
    case response.private[:troupe] do
      nil ->
        {:error, :no_stream_received}

      %{acc: acc} ->
        # The gateway's headers are read here rather than in the collector because they
        # belong to the HTTP response and not to the event stream: a gateway sends them
        # once, before the first chunk, and the collector never sees them.
        answer = Collector.to_response(acc)
        {:ok, %{answer | gateway: Gateway.from_headers(response.headers)}}
    end
  end

  # -- streaming events -------------------------------------------------------

  defp apply_event(acc, %{"choices" => choices} = event, sink) do
    acc = Collector.add_usage(acc, usage(event["usage"]))

    Enum.reduce(choices, acc, fn choice, acc ->
      acc
      |> apply_delta(choice["delta"] || %{}, sink)
      |> apply_finish(choice["finish_reason"])
    end)
  end

  defp apply_event(acc, %{"usage" => usage}, _sink), do: Collector.add_usage(acc, usage(usage))
  defp apply_event(acc, _event, _sink), do: acc

  defp apply_delta(acc, delta, sink) do
    acc
    |> apply_content(delta["content"], sink)
    |> apply_reasoning(delta["reasoning_content"] || delta["reasoning"], sink)
    |> apply_tool_calls(delta["tool_calls"], sink)
  end

  defp apply_content(acc, content, sink) when is_binary(content) and content != "" do
    emit(sink, Delta.text(content))
    Collector.append_text(acc, content)
  end

  defp apply_content(acc, _content, _sink), do: acc

  # Reasoning arrives as a sibling of `content` (DeepSeek, vLLM, LiteLLM, Mistral, GLM…):
  # shown live under its own kind so a client can fold it, and kept, because a thinking
  # model that has made one tool call rejects every later turn that does not hand its
  # reasoning back (Decision 658).
  defp apply_reasoning(acc, reasoning, sink) when is_binary(reasoning) and reasoning != "" do
    emit(sink, Delta.reasoning(reasoning))
    Collector.append_reasoning(acc, reasoning)
  end

  defp apply_reasoning(acc, _reasoning, _sink), do: acc

  defp apply_tool_calls(acc, nil, _sink), do: acc

  defp apply_tool_calls(acc, calls, sink) do
    Enum.reduce(calls, acc, &apply_tool_call(&1, &2, sink))
  end

  defp apply_tool_call(call, acc, sink) do
    index = call["index"] || 0
    function = call["function"] || %{}

    acc
    |> open_tool(index, call["id"], function["name"], sink)
    |> append_arguments(index, function["arguments"], sink)
  end

  defp open_tool(acc, _index, nil, nil, _sink), do: acc

  defp open_tool(acc, index, id, name, sink) do
    if name, do: emit(sink, %Delta{kind: :tool_use_start, id: id, name: name})
    Collector.open_tool(acc, index, id, name)
  end

  defp append_arguments(acc, _index, nil, _sink), do: acc

  defp append_arguments(acc, index, fragment, sink) do
    emit(sink, %Delta{kind: :tool_input, fragment: fragment})
    Collector.append_tool_arguments(acc, index, fragment)
  end

  defp apply_finish(acc, nil), do: acc
  defp apply_finish(acc, reason), do: Collector.put_stop_reason(acc, stop_reason(reason))

  defp emit(%{reply_to: reply_to, ref: ref}, delta), do: send(reply_to, {:llm_delta, ref, delta})

  # -- request shaping --------------------------------------------------------

  defp body(%Request{} = request) do
    %{
      model: request.model,
      stream: true,
      messages: encode_messages(request)
    }
    |> put_output_cap(request.max_tokens, request.reasoning_effort)
    |> maybe_put(:temperature, request.temperature)
    |> maybe_put(:tools, encode_tools(request.tools))
    # Usage is not reported in a stream unless it is asked for; providers that do not
    # know the option ignore it, and the ones that do give the agent real numbers to
    # budget with.
    |> maybe_put(:stream_options, stream_options(request))
    # Who this call is for. `user` is the OpenAI-compatible field every gateway
    # understands; `metadata` is what LiteLLM records alongside its own request id, which
    # is what lets the plane's ledger and the gateway's spend records be reconciled
    # against each other rather than compared by timestamp.
    |> maybe_put(:user, request.attribution[:owner])
    |> maybe_put(:metadata, metadata(request))
  end

  defp metadata(%Request{attribution: attribution}) when map_size(attribution) == 0, do: nil

  defp metadata(%Request{attribution: attribution}) do
    attribution
    |> Enum.flat_map(fn
      {_key, nil} -> []
      {key, value} -> [{"troupe_" <> to_string(key), to_string(value)}]
    end)
    |> Map.new()
  end

  defp stream_options(%Request{}), do: %{include_usage: true}

  # A reasoning model rejects `max_tokens` and counts its reasoning against
  # `max_completion_tokens`; a plain OpenAI-compatible server knows only `max_tokens`. A
  # configured effort is what says which kind this is, and it goes out verbatim — "none"
  # is as meaningful as "xhigh", and only the model knows which levels it has.
  defp put_output_cap(body, max, nil), do: Map.put(body, :max_tokens, max)

  defp put_output_cap(body, max, effort) do
    body |> Map.put(:max_completion_tokens, max) |> Map.put(:reasoning_effort, effort)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.description,
          parameters: tool.schema
        }
      }
    end)
  end

  defp encode_messages(%Request{system: system, messages: messages}) do
    system_messages = if system, do: [%{role: "system", content: system}], else: []
    system_messages ++ Enum.flat_map(messages, &encode_message/1)
  end

  # A user message holding tool results becomes one `role: "tool"` message per result,
  # which is the shape this API expects; anything else keeps its role.
  defp encode_message(%Message{role: :user, content: content}) do
    {results, rest} = Enum.split_with(content, &match?(%ToolResult{}, &1))

    tool_messages =
      Enum.map(results, fn %ToolResult{} = result ->
        %{role: "tool", tool_call_id: result.tool_use_id, content: result.content}
      end)

    text = join_text(rest)
    tool_messages ++ if(text == "", do: [], else: [%{role: "user", content: text}])
  end

  defp encode_message(%Message{role: :assistant, content: content}) do
    tool_calls =
      content
      |> Enum.filter(&match?(%ToolUse{}, &1))
      |> Enum.map(fn %ToolUse{} = call ->
        %{
          id: call.id,
          type: "function",
          function: %{name: call.name, arguments: Jason.encode!(call.input)}
        }
      end)

    message = %{role: "assistant", content: join_text(content)} |> put_reasoning(content)
    [if(tool_calls == [], do: message, else: Map.put(message, :tool_calls, tool_calls))]
  end

  defp encode_message(%Message{role: role, content: content}) do
    [%{role: Atom.to_string(role), content: join_text(content)}]
  end

  # Reasoning goes back where it came from: a sibling of `content`, and only what this
  # adapter's provider produced. DeepSeek's thinking mode is all-or-nothing — once one
  # assistant message in the history carried `reasoning_content`, one that omits it fails
  # the request with a 400 — and another provider's reasoning is not ours to replay.
  defp put_reasoning(message, content) do
    case Message.reasoning_of(content, :openai) do
      [] -> message
      reasoning -> Map.put(message, :reasoning_content, Enum.map_join(reasoning, & &1.text))
    end
  end

  defp join_text(content) do
    content
    |> Enum.flat_map(fn
      %Text{text: text} -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp usage(nil), do: %Usage{}

  # `prompt_tokens` counts the cached tokens too, so they come back out of it and the
  # three input figures stay disjoint (Decision 657). `completion_tokens` includes the
  # reasoning tokens of a model that reasons — DeepSeek and the OpenAI reasoning models
  # bill them as output, and so does the budget.
  defp usage(map) do
    prompt = count(map["prompt_tokens"])
    cached = count(get_in(map, ["prompt_tokens_details", "cached_tokens"]))

    %Usage{
      input_tokens: max(prompt - cached, 0),
      output_tokens: count(map["completion_tokens"]),
      cache_read: cached
    }
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_other), do: 0

  defp stop_reason("stop"), do: :end_turn
  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("function_call"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason("content_filter"), do: :refusal
  defp stop_reason(_), do: :other

  defp base_url(%Request{base_url: nil}), do: @default_base_url
  defp base_url(%Request{base_url: url}), do: url

  # `OPENAI_API_KEY` is OpenAI's key, so it goes to OpenAI's endpoint and nowhere else:
  # a gateway or a local server configured without a key is sent none.
  defp api_key(%Request{api_key: key}) when is_binary(key) and key != "", do: key

  defp api_key(%Request{base_url: url}) do
    if var = Endpoint.vendor_key_var(:openai, url), do: System.get_env(var)
  end

  defp describe(%{"error" => %{"message" => message}}), do: message
  defp describe(body) when is_binary(body), do: String.slice(body, 0, 400)
  defp describe(body), do: body |> inspect() |> String.slice(0, 400)
end

defmodule Troupe.LLM.Providers.OpenAI.Collector do
  @moduledoc """
  Accumulates a streamed Chat Completions response.

  Tool calls arrive by index across many chunks — an id and name in one, argument
  fragments in others — so they are reassembled by index and parsed once at the end.
  """

  alias Troupe.LLM.{Reasoning, Response, Text, ToolUse, Usage}

  defstruct text: "", reasoning: "", tools: %{}, usage: %Usage{}, stop_reason: :end_turn

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec append_text(t(), String.t()) :: t()
  def append_text(acc, text), do: %{acc | text: acc.text <> text}

  @spec append_reasoning(t(), String.t()) :: t()
  def append_reasoning(acc, text), do: %{acc | reasoning: acc.reasoning <> text}

  @spec open_tool(t(), non_neg_integer(), String.t() | nil, String.t() | nil) :: t()
  def open_tool(acc, index, id, name) do
    tools =
      Map.update(acc.tools, index, %{id: id, name: name, arguments: ""}, fn existing ->
        %{existing | id: existing.id || id, name: existing.name || name}
      end)

    %{acc | tools: tools}
  end

  @spec append_tool_arguments(t(), non_neg_integer(), String.t()) :: t()
  def append_tool_arguments(acc, index, fragment) do
    tools =
      Map.update(acc.tools, index, %{id: nil, name: nil, arguments: fragment}, fn existing ->
        %{existing | arguments: existing.arguments <> fragment}
      end)

    %{acc | tools: tools}
  end

  @spec add_usage(t(), Usage.t()) :: t()
  def add_usage(acc, %Usage{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}),
    do: acc

  def add_usage(acc, usage), do: %{acc | usage: usage}

  @spec put_stop_reason(t(), atom()) :: t()
  def put_stop_reason(acc, reason), do: %{acc | stop_reason: reason}

  @spec to_response(t()) :: Response.t()
  def to_response(%__MODULE__{} = acc) do
    text_blocks = if acc.text == "", do: [], else: [%Text{text: acc.text}]

    reasoning_blocks =
      if acc.reasoning == "",
        do: [],
        else: [%Reasoning{provider: :openai, text: acc.reasoning}]

    tool_blocks =
      acc.tools
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.flat_map(fn {index, tool} -> materialise(index, tool) end)

    stop_reason = if tool_blocks == [], do: acc.stop_reason, else: :tool_use

    %Response{
      content: reasoning_blocks ++ text_blocks ++ tool_blocks,
      stop_reason: stop_reason,
      usage: acc.usage
    }
  end

  defp materialise(index, %{name: name} = tool) when is_binary(name) do
    [
      %ToolUse{
        # Some compatible servers omit the id; the model still needs a stable one to
        # match a result against, so the index supplies it.
        id: tool.id || "call_#{index}",
        name: name,
        input: decode_arguments(tool.arguments)
      }
    ]
  end

  defp materialise(_index, _tool), do: []

  # Malformed arguments still reach the agent, which turns them into an error tool
  # result the model can see and correct — better than dropping the call.
  defp decode_arguments(""), do: %{}

  defp decode_arguments(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"__malformed_arguments__" => raw}
    end
  end
end
