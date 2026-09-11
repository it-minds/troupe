defmodule Troupe.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API adapter with native tool use and SSE streaming.
  Config: `%{api_key, base_url}`; `ANTHROPIC_API_KEY` is the fallback key.
  """

  @behaviour Troupe.LLM.Provider

  alias Troupe.LLM.{HTTP, Message, Provider, Request}

  @version "2023-06-01"

  @impl true
  def stream(config, %Request{} = request, reply_to, ref) do
    url =
      (config[:base_url] || "https://api.anthropic.com")
      |> String.trim_trailing("/")
      |> Kernel.<>("/v1/messages")

    key = config[:api_key] || System.get_env("ANTHROPIC_API_KEY") || ""

    headers = [
      {"x-api-key", key},
      {"anthropic-version", @version},
      {"content-type", "application/json"}
    ]

    body = encode(request)

    acc0 = %{
      blocks: %{},
      usage: %{input_tokens: 0, output_tokens: 0},
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

  @doc false
  def encode(%Request{} = r) do
    %{
      model: r.model,
      max_tokens: r.max_tokens,
      stream: true,
      system: r.system,
      messages: Enum.map(r.messages, &encode_message/1),
      tools:
        Enum.map(
          r.tools,
          &%{name: &1.name, description: &1.description, input_schema: &1.input_schema}
        )
    }
    |> then(fn m -> if r.tools == [], do: Map.delete(m, :tools), else: m end)
  end

  defp encode_message(%{role: role, content: blocks}) do
    %{role: role, content: Enum.map(blocks, &encode_block/1)}
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
    usage = Map.get(msg, "usage", %{})

    %{
      acc
      | usage: %{acc.usage | input_tokens: Map.get(usage, "input_tokens", 0)},
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

      _ ->
        acc
    end
  end

  defp apply_event(%{"type" => "message_delta"} = ev, acc) do
    stop = get_in(ev, ["delta", "stop_reason"])
    out = get_in(ev, ["usage", "output_tokens"]) || acc.usage.output_tokens

    %{
      acc
      | stop_reason: stop_reason(stop || acc.stop_reason),
        usage: %{acc.usage | output_tokens: out}
    }
  end

  defp apply_event(%{"type" => "error", "error" => err}, acc) do
    send(acc.reply_to, {:llm_delta, acc.ref, ""})
    Map.put(acc, :error, err)
  end

  defp apply_event(_other, acc), do: acc

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
