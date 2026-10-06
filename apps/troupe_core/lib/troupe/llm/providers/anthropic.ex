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

  alias Troupe.LLM.{Catalog, Endpoint, Identify}
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
      {:refused, _why} = refused -> {:error, refused}
      key -> post_kept(request, key, reply_to, ref)
    end
  end

  # A thinking block the conversation no longer vouches for is answered by the same call
  # with no thinking in it, once (Decision 805).
  defp post_kept(request, key, reply_to, ref) do
    with :bound_elsewhere <- post(request, key, reply_to, ref, :first),
         do: post(request, key, reply_to, ref, :without_thinking)
  end

  defp post(request, key, reply_to, ref, pass) do
    thinking = thinking(request)
    keep_thinking? = pass == :first and keep_thinking?(request, thinking)

    options = [
      url: Endpoint.build(base_url(request), "/v1/messages"),
      method: :post,
      json: body(request, thinking, keep_thinking?),
      headers:
        [
          auth_header(request, key),
          {"anthropic-version", @api_version},
          {"accept", "text/event-stream"}
        ] ++ Identify.headers(request, :anthropic),
      receive_timeout: request.timeout_ms,
      # Retries are handled by `Provider.with_retries/2` so that one policy covers
      # both adapters and a retried request re-emits nothing to the agent.
      retry: false,
      # An error's body is read here, JSON or not (Decision 791).
      decode_body: false,
      # Req threads streaming state through `{req, resp}`; keeping the accumulator in
      # the response's private map means it lives and dies with this one request.
      into: fn {:data, chunk}, {req, resp} ->
        {:cont, {req, handle_chunk(resp, chunk, reply_to, ref)}}
      end
    ]

    case options |> Req.new() |> with_transport(request) |> Req.request() do
      {:ok, %Req.Response{status: 200} = response} ->
        finish(response, key)

      # A rate limit says how long to wait, when it says anything; the retry policy
      # takes the hint (Decision 659). What the provider said goes with the status, so
      # one the retries outlast says it (Decision 805).
      {:ok, %Req.Response{status: 429, body: body} = response} ->
        {:retry, {:http_status, 429, detail(body, key)},
         Provider.retry_after_ms(response.headers)}

      {:ok, %Req.Response{status: status, body: body}} when status >= 500 ->
        {:retry, {:http_status, status, detail(body, key)}}

      {:ok, %Req.Response{status: 400, body: body}} ->
        refused(detail(body, key), thinking, request, keep_thinking?)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, detail(body, key)}}

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

  # Req hands `into` the body of every response, whatever its status. Only a 200's is the
  # event stream; any other's is the provider's error, kept for `post/4` to read rather
  # than fed to the parser, where it was lost (Decision 791).
  defp handle_chunk(%Req.Response{status: status} = resp, chunk, _reply_to, _ref)
       when status != 200,
       do: Provider.collect_error(resp, chunk)

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

  defp finish(%Req.Response{} = response, key) do
    case response.private[:troupe] do
      nil ->
        {:error, :no_stream_received}

      # An error inside the stream is said as an error response is: trimmed, and with no
      # key in it (Decisions 791 and 805).
      %{acc: %Collector{error: error}} when is_binary(error) ->
        {:error, {:api_error, Provider.error_text(error, key)}}

      %{acc: acc} ->
        # The gateway's headers are read here rather than in the collector because they
        # belong to the HTTP response and not to the event stream: a gateway sends them
        # once, before the first chunk, and the collector never sees them.
        answer = Collector.to_response(acc)
        {:ok, %{answer | gateway: Gateway.from_headers(response.headers)}}
    end
  end

  # -- streaming events -------------------------------------------------------

  defp apply_event(acc, %{"type" => "message_start", "message" => message}, collector) do
    merge_usage(acc, message["usage"], collector)
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

  defp apply_event(acc, %{"type" => "message_delta"} = event, collector) do
    # `message_delta` reports running totals for the message, not increments, so each
    # figure it carries replaces the one from `message_start` rather than adding to it.
    acc
    |> Collector.put_stop_reason(stop_reason(get_in(event, ["delta", "stop_reason"])))
    |> merge_usage(event["usage"], collector)
  end

  defp apply_event(acc, %{"type" => "error", "error" => error}, _collector) do
    Collector.put_error(acc, describe(error))
  end

  defp apply_event(acc, _event, _collector), do: acc

  defp emit(%{reply_to: reply_to, ref: ref}, delta) do
    send(reply_to, {:llm_delta, ref, delta})
  end

  # What the provider has reported so far goes to the agent as it comes, so a call the
  # agent stops before it answers is counted for what it used (Decision 788).
  defp merge_usage(acc, reported, %{reply_to: reply_to, ref: ref}) do
    merged = Collector.merge_usage(acc, reported)
    if merged.usage != acc.usage, do: send(reply_to, {:llm_usage, ref, merged.usage})
    merged
  end

  # -- request shaping --------------------------------------------------------

  defp body(%Request{} = request, thinking, keep_thinking?) do
    %{
      model: request.model,
      max_tokens: request.max_tokens,
      stream: true,
      messages:
        request.messages
        |> Enum.map(&encode_message(&1, keep_thinking?))
        |> mark_messages(request.cache)
    }
    |> maybe_put(:system, encode_system(request))
    |> maybe_put(:temperature, request.temperature)
    |> maybe_put(:tools, request.tools |> encode_tools() |> mark_last(request.cache))
    # Anthropic takes one opaque end-user id and nothing else, so the session's owner
    # goes there. Everything else a gateway wants is carried by the OpenAI-compatible
    # adapter, which is what a LiteLLM deployment actually speaks. A local session sends
    # none: one id for every person would be one user to Anthropic, and the User-Agent
    # already names the software (Decision 787).
    |> maybe_put(:metadata, metadata(request))
    |> put_thinking(thinking)
  end

  # Anthropic's models take thinking in one of two forms, and refuse the other with a 400
  # (Decision 780). Those before Claude Opus 4.7 take a budget in tokens; from Opus 4.7 on
  # a budget is refused and they take adaptive thinking with an effort level. Which one a
  # model takes is what the provider's own model list says (`Request.thinking`), else what
  # its name says (`Catalog.thinking/1`), else — a model nothing describes — the newer form
  # for a level and a budget for a number of tokens, which is what a number asks for.
  #
  # Either way the configured effort sets how much room the thinking gets: a budget is it,
  # and adaptive thinking spends from `max_tokens` just the same, so the output cap is
  # raised to hold it rather than the request failing or the reply being cut (Decision
  # 658). Adaptive thinking asks for a summary of the thinking, which is what the newest
  # models otherwise leave out, so it still streams as reasoning.
  defp thinking(%Request{reasoning_effort: effort} = request) do
    case room(effort) do
      nil ->
        nil

      room ->
        {form, why} = form(request)
        %{form: form, why: why, effort: effort, room: room, level: level(effort, room)}
    end
  end

  defp form(%Request{thinking: listed}) when listed in [:adaptive, :budget], do: {listed, :listed}

  defp form(%Request{model: model, reasoning_effort: effort}) do
    case Catalog.thinking(model) do
      nil -> if number?(effort), do: {:budget, :effort}, else: {:adaptive, :effort}
      named -> {named, :name}
    end
  end

  defp put_thinking(body, nil), do: body

  defp put_thinking(body, %{form: :budget, room: budget}) do
    body
    |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
    |> Map.put(:max_tokens, max(body.max_tokens, budget + 4_096))
  end

  defp put_thinking(body, %{form: :adaptive, room: room, level: level}) do
    body
    |> Map.put(:thinking, %{type: "adaptive", display: "summarized"})
    |> Map.put(:output_config, %{effort: level})
    |> Map.put(:max_tokens, max(body.max_tokens, room + 4_096))
  end

  # The tokens a configured effort gives the thinking: the budget itself, for a model that
  # takes one.
  defp room(effort) when effort in [nil, "none", "off"], do: nil
  defp room("minimal"), do: 1_024
  defp room("low"), do: 4_096
  defp room("medium"), do: 8_192
  defp room("high"), do: 16_384
  defp room(level) when level in ["xhigh", "max"], do: 32_768

  defp room(other) when is_binary(other) do
    case Integer.parse(other) do
      {n, ""} when n >= 1_024 -> n
      _ -> nil
    end
  end

  # Anthropic's five levels. A word is the level of the same name (`minimal`, which it
  # has none of, is `low`); a number of tokens is the level whose budget above would hold
  # it, and more than `xhigh`'s is `max`.
  defp level(word, _room) when word in ["low", "medium", "high", "xhigh", "max"], do: word
  defp level("minimal", _room), do: "low"
  defp level(_number, room) when room <= 4_096, do: "low"
  defp level(_number, room) when room <= 8_192, do: "medium"
  defp level(_number, room) when room <= 16_384, do: "high"
  defp level(_number, room) when room <= 32_768, do: "xhigh"
  defp level(_number, _room), do: "max"

  defp number?(effort), do: match?({_n, ""}, Integer.parse(effort))

  # Whether the model's own thinking goes back to it (Decision 805): when the request
  # turns thinking on, and when the model thinks with no `thinking` field at all, as
  # Anthropic's newest do, most of them with no way to be told not to. Their thinking,
  # signed, is how a tool-use turn keeps the reasoning it started with; dropped, the model
  # went on without it.
  defp keep_thinking?(_request, thinking) when thinking != nil, do: true
  defp keep_thinking?(%Request{model: model}, nil), do: Catalog.thinks_unasked?(model)

  # A 400 that is about the thinking this request carried is said in words that name the
  # setting behind it; any other 400 goes as the provider put it. What the provider says
  # differs by model and form ("thinking.type.enabled" is not supported…, an `adaptive`
  # tag it does not expect, `output_config` it does not take), and all of it names one
  # of these.
  @thinking_words ["thinking.type", "budget_tokens", "adaptive", "output_config", "effort"]

  # The newest models check a thinking block sent back against the conversation it was
  # made in, for accounts the check is enforced for, and refuse one that conversation no
  # longer vouches for — after an edit to the system prompt, say — with a 400 that says
  # so. The API's documented way on is the request again with no thinking in it, which is
  # what every one of these requests was before Decision 805: `:bound_elsewhere` asks for
  # it.
  @bound_elsewhere "Invalid `signature` in `thinking` block"

  defp refused(detail, thinking, request, keep_thinking?) do
    cond do
      keep_thinking? and String.contains?(detail, @bound_elsewhere) ->
        :bound_elsewhere

      thinking && String.contains?(detail, @thinking_words) ->
        {:error, {:thinking_refused, refusal(thinking, request), detail}}

      true ->
        {:error, {:http_status, 400, detail}}
    end
  end

  defp refusal(thinking, %Request{model: model}) do
    sent =
      case thinking.form do
        :adaptive -> "adaptive thinking at effort #{thinking.level}"
        :budget -> "a thinking budget of #{thinking.room} tokens"
      end

    "#{model} refused #{sent}, which reasoning_effort #{thinking.effort} asks for; " <>
      change(thinking)
  end

  # For a model Troupe knows, the form is the model's and only the effort can go; for one
  # it does not, the kind of value picks the form, so the other kind may be the answer.
  defp change(%{why: :effort, form: :adaptive}),
    do:
      "for a model Troupe has no listing for, a number of tokens sends a thinking budget " <>
        "instead: set reasoning_effort in the model's models: entry to one, such as 16384, " <>
        "or remove it to send no thinking"

  defp change(%{why: :effort, form: :budget}),
    do:
      "for a model Troupe has no listing for, a level sends adaptive thinking instead: set " <>
        "reasoning_effort in the model's models: entry to low, medium, high, xhigh or max, " <>
        "or remove it to send no thinking"

  defp change(_known), do: "remove reasoning_effort from the model's models: entry to send no thinking"

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

  # Anthropic caches nothing it is not asked to: a block marked `cache_control` caches
  # the prompt up to and including it, in the order tools, system, messages, and a later
  # request that repeats a marked prefix reads it at a fraction of the input price. Four
  # marks at most, and each one sits where what comes before it stays the same from call
  # to call (Decision 770):
  #
  #   * the last tool, so the tools stay cached when the system prompt changes;
  #   * the system prompt, without the tail that changes from one turn to the next — the
  #     task list (Decision 792), which goes after the mark as a block of its own;
  #   * the last block of each of the last two user messages: the newest one writes the
  #     whole conversation for the next call, and the one before is where the previous
  #     call's mark was, so that call's cache is read whatever came in between.
  #
  # A prompt shorter than the model's minimum is not cached and nothing fails; five
  # minutes is the cache's life, and each read renews it.
  @cache_control %{type: "ephemeral"}

  defp encode_system(%Request{cache: true, system: system} = request)
       when is_binary(system) and system != "" do
    tail =
      if request.system_tail in [nil, ""],
        do: [],
        else: [%{type: "text", text: request.system_tail}]

    [%{type: "text", text: system, cache_control: @cache_control} | tail]
  end

  defp encode_system(%Request{} = request), do: Request.system_text(request)

  defp mark_last(nil, _cache?), do: nil
  defp mark_last(blocks, false), do: blocks
  defp mark_last([], true), do: []

  defp mark_last(blocks, true),
    do: List.update_at(blocks, -1, &Map.put(&1, :cache_control, @cache_control))

  defp mark_messages(messages, false), do: messages

  defp mark_messages(messages, true) do
    marked =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {message, _index} -> message.role == "user" and message.content != [] end)
      |> Enum.take(-2)
      |> MapSet.new(fn {_message, index} -> index end)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      if MapSet.member?(marked, index),
        do: %{message | content: mark_last(message.content, true)},
        else: message
    end)
  end

  defp encode_message(%Message{role: role, content: content}, keep_thinking?) do
    blocks = Enum.reject(content, &drop_reasoning?(&1, keep_thinking?))
    %{role: Atom.to_string(role), content: Enum.map(blocks, &encode_block/1)}
  end

  # Which reasoning may go back out. Another provider's thinking carries no signature
  # Anthropic can verify, and a thinking block is only legal on a request the model thinks
  # on — one with thinking enabled, or to a model that thinks unasked (Decision 805) — so
  # with thinking off, or for anything that came from an OpenAI-compatible provider, the
  # block is dropped and the rest of the turn goes unchanged.
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
  defp stop_reason("refusal"), do: :refusal
  defp stop_reason(_), do: :other

  defp base_url(%Request{base_url: nil}), do: @default_base_url
  defp base_url(%Request{base_url: url}), do: url

  # `ANTHROPIC_API_KEY` is Anthropic's key, so it goes to Anthropic's endpoint and
  # nowhere else: a gateway that was configured without a key does not get it.
  defp api_key(%Request{api_key: {:refused, _why} = refused}), do: refused
  defp api_key(%Request{api_key: key}) when is_binary(key) and key != "", do: key

  defp api_key(%Request{base_url: url}) do
    if var = Endpoint.vendor_key_var(:anthropic, url), do: System.get_env(var)
  end

  # Anthropic's own scheme is `x-api-key`; a gateway in front of its API usually wants
  # the same token as a bearer, which is what `auth_token` in a config file says.
  defp auth_header(%Request{auth: :bearer}, key), do: {"authorization", "Bearer " <> key}
  defp auth_header(_request, key), do: {"x-api-key", key}

  # What an error response said, as a person reads it: no key in it (Decision 791).
  defp detail(body, key), do: body |> describe() |> Provider.error_text(key)

  # An error response is `{"type": "error", "error": {"type": …, "message": …}}`, which
  # arrives as the text `into` collected; an error inside the stream is the inner object
  # alone.
  defp describe(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp describe(%{"message" => message}) when is_binary(message), do: message

  defp describe(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> describe(decoded)
      _not_json -> String.slice(body, 0, 400)
    end
  end

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
