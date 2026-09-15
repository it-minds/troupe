defmodule Troupe.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible Chat Completions adapter (function calling, SSE) working
  against any base URL: LiteLLM, vLLM, Mistral and similar.
  Config is `Troupe.LLM.Provider.config()`: `api_key` (`OPENAI_API_KEY` is the
  fallback), `base_url`, `reasoning_effort` and `max_output`. The key always goes
  out as a bearer token, so `auth` is not consulted.
  """

  @behaviour Troupe.LLM.Provider

  alias Troupe.LLM.{HTTP, Message, Provider, Request}

  @impl true
  def stream(config, %Request{} = request, reply_to, ref) do
    url = HTTP.api_url(config[:base_url] || "https://api.openai.com/v1", "/chat/completions")
    key = config[:api_key] || System.get_env("OPENAI_API_KEY") || ""
    headers = [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}]
    body = encode(request, config)

    acc0 = %{
      text: "",
      calls: %{},
      usage: Provider.empty_usage(),
      finish: nil,
      model: request.model,
      reply_to: reply_to,
      ref: ref
    }

    result =
      case post(url, headers, body, acc0) do
        {:error, {:http, 400, detail}} = refused ->
          case output_cap_retry(body, detail) do
            nil -> refused
            retry -> post(url, headers, retry, acc0)
          end

        other ->
          other
      end

    case result do
      {:ok, acc} -> send(reply_to, {:llm_done, ref, finalize(acc)})
      {:error, reason} -> send(reply_to, {:llm_error, ref, reason})
    end

    :ok
  end

  defp post(url, headers, body, acc0) do
    Provider.with_retries(fn -> HTTP.stream_post(url, headers, body, acc0, &handle_event/3) end)
  end

  # A reasoning model refuses `max_tokens` and asks for `max_completion_tokens`
  # by name; a plain OpenAI-compatible server knows only the first. Nothing in a
  # model id says which, but the 400 says exactly which — so the request that
  # finds out is sent again with the other field instead of making every user
  # discover this and configure it. A model with a declared `reasoning_effort`
  # starts with the right field and never gets here.
  @doc false
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

  @doc false
  def encode(%Request{} = r, config \\ %{}) do
    messages = [%{role: "system", content: r.system} | Enum.flat_map(r.messages, &encode_message/1)]

    base =
      %{
        model: r.model,
        stream: true,
        stream_options: %{include_usage: true},
        messages: messages
      }
      |> put_output_cap(config[:max_output] || r.max_tokens, Provider.effort(r, config))

    if r.tools == [] do
      base
    else
      Map.put(
        base,
        :tools,
        Enum.map(
          r.tools,
          &%{
            type: "function",
            function: %{name: &1.name, description: &1.description, parameters: &1.input_schema}
          }
        )
      )
    end
  end

  # A reasoning model rejects `max_tokens` and counts its reasoning against
  # `max_completion_tokens`; a plain OpenAI-compatible server only knows
  # `max_tokens`. A configured effort is what says which kind this is, and it goes
  # out verbatim — "none" is as meaningful as "xhigh" and only the model knows
  # which levels it has.
  defp put_output_cap(body, max, nil), do: Map.put(body, :max_tokens, max)

  defp put_output_cap(body, max, effort),
    do: body |> Map.put(:max_completion_tokens, max) |> Map.put(:reasoning_effort, effort)

  defp encode_message(%{role: :user, content: blocks}) do
    {results, texts} = Enum.split_with(blocks, &match?(%{type: :tool_result}, &1))

    Enum.map(results, fn r -> %{role: "tool", tool_call_id: r.tool_use_id, content: r.content} end) ++
      case Message.text(texts) do
        "" -> []
        text -> [%{role: "user", content: text}]
      end
  end

  defp encode_message(%{role: :assistant, content: blocks}) do
    calls =
      blocks
      |> Message.tool_uses()
      |> Enum.map(
        &%{
          id: &1.id,
          type: "function",
          function: %{name: &1.name, arguments: Jason.encode!(&1.input)}
        }
      )

    msg = %{role: "assistant", content: Message.text(blocks)}
    [if(calls == [], do: msg, else: Map.put(msg, :tool_calls, calls))]
  end

  @doc false
  def handle_event(_event, "[DONE]", acc), do: acc

  def handle_event(_event, data, acc) do
    case Jason.decode(data) do
      {:ok, json} -> apply_chunk(json, acc)
      {:error, _} -> acc
    end
  end

  defp apply_chunk(json, acc) do
    acc =
      case Map.get(json, "usage") do
        %{"prompt_tokens" => p, "completion_tokens" => c} = u ->
          # `prompt_tokens` counts the cached tokens too, so the cached ones come
          # back out of it: `Provider.usage` keeps the three input figures disjoint.
          cached = get_in(u, ["prompt_tokens_details", "cached_tokens"]) || 0

          %{
            acc
            | usage: %{
                input_tokens: max(p - cached, 0),
                output_tokens: c,
                cache_read: cached,
                cache_write: 0
              }
          }

        _ ->
          acc
      end

    acc = if m = Map.get(json, "model"), do: %{acc | model: m}, else: acc

    json
    |> Map.get("choices", [])
    |> Enum.reduce(acc, fn choice, a ->
      delta = Map.get(choice, "delta", %{})
      a = if fr = Map.get(choice, "finish_reason"), do: %{a | finish: fr}, else: a

      a =
        case Map.get(delta, "content") do
          t when is_binary(t) and t != "" ->
            send(a.reply_to, {:llm_delta, a.ref, t})
            %{a | text: a.text <> t}

          _ ->
            a
        end

      # reasoning / thinking tokens (vLLM, LiteLLM, Mistral, GLM...): shown live, not kept
      case Map.get(delta, "reasoning_content") || Map.get(delta, "reasoning") do
        r when is_binary(r) and r != "" -> send(a.reply_to, {:llm_delta, a.ref, r})
        _ -> :ok
      end

      Enum.reduce(Map.get(delta, "tool_calls") || [], a, fn tc, a2 ->
        idx = Map.get(tc, "index", 0)
        existing = Map.get(a2.calls, idx, %{id: nil, name: "", args: ""})
        fun = Map.get(tc, "function", %{})

        updated = %{
          existing
          | id: Map.get(tc, "id") || existing.id,
            name: existing.name <> (Map.get(fun, "name") || ""),
            args: existing.args <> (Map.get(fun, "arguments") || "")
        }

        %{a2 | calls: Map.put(a2.calls, idx, updated)}
      end)
    end)
  end

  defp finalize(acc) do
    calls =
      acc.calls
      |> Enum.sort_by(fn {i, _} -> i end)
      |> Enum.map(fn {i, c} ->
        Message.tool_use(c.id || "call_#{i}", c.name, decode_args(c.args))
      end)

    text = if acc.text == "", do: [], else: [Message.text_block(acc.text)]
    stop = if calls == [], do: :end_turn, else: :tool_use
    %{content: text ++ calls, usage: acc.usage, stop_reason: stop, model: acc.model}
  end

  defp decode_args(""), do: %{}

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"_raw" => json}
    end
  end
end
