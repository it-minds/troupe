defmodule Troupe.Test.ModelStream do
  @moduledoc """
  A scripted answer as a model provider streams it, for the stand-ins on a loopback port
  (`Troupe.Test.ErrorStandIn`, `Troupe.Test.PromptCacheStandIn`).

  An answer is `{:text, text}` or `{:tool, name, input}`. `POST /v1/messages` is
  Anthropic's shape and `usage` is what its `message_start` reports; `POST
  /v1/chat/completions` is an OpenAI-compatible server's and `usage` is what its last
  chunk reports. Either way the answer itself counts as ten output tokens.
  """

  import Troupe.Test.LoopbackHTTP, only: [event: 2, data: 1]

  @doc "The events of answer `n` on `path`."
  @spec events(String.t(), pos_integer(), tuple(), map()) :: iodata()
  def events("/v1/messages", n, answer, usage) do
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

  def events("/v1/chat/completions", n, answer, usage) do
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
end
