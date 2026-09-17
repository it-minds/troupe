defmodule Troupe.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API adapter with native tool use and SSE streaming.
  Config is `Troupe.LLM.Provider.config()`: `api_key` (`ANTHROPIC_API_KEY` is the
  fallback), `base_url`, `auth` (`:bearer` sends the key as `Authorization: Bearer`
  for a gateway that speaks the Messages API but not `x-api-key`),
  `reasoning_effort` and `max_output`.
  """

  @behaviour Troupe.LLM.Provider

  alias Troupe.LLM.{HTTP, Message, Provider, Request}

  @version "2023-06-01"

  @impl true
  def stream(config, %Request{} = request, reply_to, ref) do
    url = HTTP.api_url(config[:base_url] || "https://api.anthropic.com", "/v1/messages")
    key = config[:api_key] || System.get_env("ANTHROPIC_API_KEY") || ""

    headers = [
      auth_header(config[:auth], key),
      {"anthropic-version", @version},
      {"content-type", "application/json"}
    ]

    body = encode(request, config)

    acc0 = %{
      blocks: %{},
      usage: Provider.empty_usage(),
      stop_reason: :end_turn,
      model: request.model,
      reply_to: reply_to,
      ref: ref
    }

    result =
      Provider.with_retries(fn -> HTTP.stream_post(url, headers, body, acc0, &handle_event/3) end)

    case result do
      {:ok, acc} -> send(reply_to, {:llm_done, ref, finalize(acc)})
      {:error, reason} -> send(reply_to, {:llm_error, ref, reason})
    end

    :ok
  end

  defp auth_header(:bearer, key), do: {"authorization", "Bearer " <> key}
  defp auth_header(_auth, key), do: {"x-api-key", key}

  @doc false
  def encode(%Request{} = r, config \\ %{}) do
    plan = cache_plan(r)

    %{
      model: r.model,
      max_tokens: config[:max_output] || r.max_tokens,
      stream: true,
      system: encode_system(r.system, plan),
      messages: r.messages |> Enum.with_index() |> Enum.map(&encode_message(&1, plan)),
      tools:
        Enum.map(
          r.tools,
          &%{name: &1.name, description: &1.description, input_schema: &1.input_schema}
        )
    }
    |> then(fn m -> if r.tools == [], do: Map.delete(m, :tools), else: m end)
    |> put_thinking(Provider.effort(r, config))
  end

  ## Prompt cache breakpoints
  #
  # The prefix renders tools, then system, then messages, and a cache entry is a
  # prefix match, so at most three markers are ever needed and they all go on
  # here rather than in anything that is stored:
  #
  #   1. the system block, which caches the tools and the system prompt together;
  #   2. the last stable block of the final message, which caches the whole
  #      conversation for the next call;
  #   3. the block that carried (2) last time, because a lookup only scans about
  #      twenty positions back from a breakpoint and a turn that appended a lot
  #      could otherwise miss the entry the previous request just wrote.
  #
  # Three is under the limit of four. A compaction request is a one-shot with a
  # different system prompt and model, so it gets none: a write nothing ever
  # reads back is a pure surcharge.

  defp cache_plan(%Request{cache: nil}), do: nil
  defp cache_plan(%Request{purpose: :compaction}), do: nil

  defp cache_plan(%Request{cache: %{ttl: ttl} = cache, messages: messages}) do
    last = length(messages) - 1

    indexes =
      [last, Map.get(cache, :previous)]
      |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 <= last))
      |> Enum.uniq()

    %{ttl: ttl, messages: indexes}
  end

  defp cache_control(%{ttl: "1h"}), do: %{type: "ephemeral", ttl: "1h"}
  defp cache_control(%{ttl: _}), do: %{type: "ephemeral"}

  defp encode_system("", _plan), do: ""
  defp encode_system(system, nil), do: system

  defp encode_system(system, plan),
    do: [%{type: "text", text: system, cache_control: cache_control(plan)}]

  defp encode_message({%{role: role, content: blocks}, index}, plan) do
    mark = breakpoint_block(blocks, index, plan)

    content =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn
        {block, ^mark} -> Map.put(encode_block(block), :cache_control, cache_control(plan))
        {block, _i} -> encode_block(block)
      end)

    %{role: role, content: content}
  end

  # The last block that will still be there next turn. A volatile block is
  # rebuilt every request, so a marker on it would write an entry nothing can
  # ever read; putting the marker before it leaves it as the uncached tail.
  defp breakpoint_block(_blocks, _index, nil), do: nil

  defp breakpoint_block(blocks, index, %{messages: indexes}) do
    if index in indexes do
      blocks
      |> Enum.with_index()
      |> Enum.reject(fn {block, _i} -> Message.volatile?(block) end)
      |> List.last()
      |> case do
        {_block, i} -> i
        nil -> nil
      end
    else
      nil
    end
  end

  # Anthropic takes a thinking budget in tokens where an OpenAI-compatible
  # provider takes an effort level, so a configured effort becomes a budget. The
  # budget has to fit inside `max_tokens`, so enabling thinking raises the output
  # cap along with it rather than failing the request.
  defp put_thinking(body, effort) do
    case budget(effort) do
      nil ->
        body

      budget ->
        body
        |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
        |> Map.put(:max_tokens, max(body.max_tokens, budget + 4_096))
    end
  end

  defp budget(effort) when effort in [nil, "none", "off"], do: nil
  defp budget("minimal"), do: 1_024
  defp budget("low"), do: 4_096
  defp budget("medium"), do: 8_192
  defp budget("high"), do: 16_384
  defp budget("xhigh"), do: 32_768

  defp budget(other) when is_binary(other) do
    case Integer.parse(other) do
      {n, ""} when n >= 1_024 -> n
      _ -> nil
    end
  end

  defp encode_block(%{type: :text, text: t}), do: %{type: "text", text: t}

  defp encode_block(%{type: :tool_use, id: id, name: n, input: i}),
    do: %{type: "tool_use", id: id, name: n, input: i}

  defp encode_block(%{type: :tool_result, tool_use_id: id, content: c, is_error: e}),
    do: %{type: "tool_result", tool_use_id: id, content: c, is_error: e}

  @doc false
  def handle_event(_event, data, acc) do
    case Jason.decode(data) do
      {:ok, json} -> apply_event(json, acc)
      {:error, _} -> acc
    end
  end

  defp apply_event(%{"type" => "message_start", "message" => msg}, acc) do
    %{
      acc
      | usage: merge_usage(acc.usage, Map.get(msg, "usage", %{})),
        model: Map.get(msg, "model", acc.model)
    }
  end

  defp apply_event(%{"type" => "content_block_start", "index" => i, "content_block" => block}, acc) do
    started =
      case block do
        %{"type" => "text"} ->
          %{type: :text, text: Map.get(block, "text", "")}

        %{"type" => "tool_use", "id" => id, "name" => name} ->
          %{type: :tool_use, id: id, name: name, json: ""}

        %{"type" => other} ->
          %{type: :other, kind: other}
      end

    %{acc | blocks: Map.put(acc.blocks, i, started)}
  end

  defp apply_event(%{"type" => "content_block_delta", "index" => i, "delta" => delta}, acc) do
    case {Map.get(acc.blocks, i), delta} do
      {%{type: :text} = b, %{"type" => "text_delta", "text" => t}} ->
        send(acc.reply_to, {:llm_delta, acc.ref, t})
        %{acc | blocks: Map.put(acc.blocks, i, %{b | text: b.text <> t})}

      {%{type: :tool_use} = b, %{"type" => "input_json_delta", "partial_json" => j}} ->
        %{acc | blocks: Map.put(acc.blocks, i, %{b | json: b.json <> j})}

      # summarized thinking is shown live (tagged, so the UI can fold it into
      # its own collapsible block) and never persisted
      {_, %{"type" => "thinking_delta", "thinking" => t}} ->
        send(acc.reply_to, {:llm_delta, acc.ref, t, :reasoning})
        acc

      _ ->
        acc
    end
  end

  defp apply_event(%{"type" => "message_delta"} = ev, acc) do
    stop = get_in(ev, ["delta", "stop_reason"])

    %{
      acc
      | stop_reason: stop_reason(stop || acc.stop_reason),
        usage: merge_usage(acc.usage, Map.get(ev, "usage") || %{})
    }
  end

  defp apply_event(%{"type" => "error", "error" => err}, acc) do
    send(acc.reply_to, {:llm_delta, acc.ref, ""})
    Map.put(acc, :error, err)
  end

  defp apply_event(_other, acc), do: acc

  # Anthropic reports the cache figures beside `input_tokens` and not inside it,
  # which is already the shape `Provider.usage` wants. They arrive on
  # `message_start`; `message_delta` carries the final output count and, on some
  # models, corrected input counts, so both go through here and a key that is
  # absent leaves what was already counted alone.
  defp merge_usage(usage, reported) do
    %{
      input_tokens: count(reported, "input_tokens", usage.input_tokens),
      output_tokens: count(reported, "output_tokens", usage.output_tokens),
      cache_read: count(reported, "cache_read_input_tokens", usage.cache_read),
      cache_write: count(reported, "cache_creation_input_tokens", usage.cache_write)
    }
  end

  defp count(reported, key, default) do
    case Map.get(reported, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end

  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("refusal"), do: :refusal
  defp stop_reason(atom) when is_atom(atom), do: atom
  defp stop_reason(_), do: :end_turn

  defp finalize(acc) do
    content =
      acc.blocks
      |> Enum.sort_by(fn {i, _} -> i end)
      |> Enum.flat_map(fn
        {_, %{type: :text, text: t}} ->
          [Message.text_block(t)]

        {_, %{type: :tool_use, id: id, name: n, json: j}} ->
          [Message.tool_use(id, n, decode_input(j))]

        _ ->
          []
      end)

    %{content: content, usage: acc.usage, stop_reason: acc.stop_reason, model: acc.model}
  end

  defp decode_input(""), do: %{}

  defp decode_input(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"_raw" => json}
    end
  end
end
