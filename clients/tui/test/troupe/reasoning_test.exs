defmodule Troupe.ReasoningTest do
  @moduledoc """
  Reasoning has to survive the whole loop: the adapter has to capture it off the
  wire, it has to persist and replay like any other block, and it has to go back
  out in the shape the provider that made it demands. A turn that drops it is a
  400 from DeepSeek in thinking mode and from Anthropic with thinking enabled,
  and only on the *second* request of a tool-using conversation — so these tests
  round-trip a two-turn tool call rather than checking a single encode.
  """
  use ExUnit.Case, async: true

  alias Troupe.LLM.{Anthropic, Message, OpenAI, Request}

  defp request(messages, opts \\ []) do
    %Request{
      model: Keyword.get(opts, :model, "claude-opus-5"),
      system: "sys",
      messages: messages,
      tools: [%{name: "read_file", description: "reads", input_schema: %{}}],
      reasoning_effort: Keyword.get(opts, :effort)
    }
  end

  # One assistant turn that thought, then called a tool, plus the tool's result:
  # exactly the history shape that fails on the next request when reasoning is lost.
  defp tool_turn(reasoning_block) do
    [
      Message.user("read mix.exs"),
      Message.assistant([
        reasoning_block,
        Message.text_block("Let me read it."),
        Message.tool_use("call_1", "read_file", %{"path" => "mix.exs"})
      ]),
      Message.user([Message.tool_result("call_1", "defmodule Troupe.MixProject", false)])
    ]
  end

  defp sse(events) do
    acc0 = %{
      blocks: %{},
      usage: Troupe.LLM.Provider.empty_usage(),
      stop_reason: :end_turn,
      model: "claude-opus-5",
      reply_to: self(),
      ref: make_ref()
    }

    Enum.reduce(events, acc0, fn json, acc ->
      Anthropic.handle_event("x", Jason.encode!(json), acc)
    end)
  end

  describe "anthropic" do
    test "captures a thinking block and its signature off the stream" do
      acc =
        sse([
          %{type: "message_start", message: %{usage: %{}, model: "claude-opus-5"}},
          %{type: "content_block_start", index: 0, content_block: %{type: "thinking"}},
          %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "thinking_delta", thinking: "I should "}
          },
          %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "thinking_delta", thinking: "read the file."}
          },
          %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "signature_delta", signature: "sig123"}
          },
          %{type: "content_block_start", index: 1, content_block: %{type: "text", text: ""}},
          %{type: "content_block_delta", index: 1, delta: %{type: "text_delta", text: "Sure."}}
        ])

      assert %{
               blocks: %{
                 0 => %{type: :reasoning, text: "I should read the file.", signature: "sig123"}
               }
             } = acc
    end

    test "re-encodes thinking, signature and order when thinking is enabled" do
      block = Message.reasoning(:anthropic, "I should read it.", signature: "sig123")
      body = Anthropic.encode(request(tool_turn(block), effort: "medium"))

      assistant = Enum.at(body.messages, 1)

      assert [thinking | rest] = assistant.content
      assert thinking == %{type: "thinking", thinking: "I should read it.", signature: "sig123"}
      assert Enum.map(rest, & &1.type) == ["text", "tool_use"]
    end

    test "redacted thinking goes back as its opaque payload" do
      block = Message.reasoning(:anthropic, "ENCRYPTED", redacted: true)
      body = Anthropic.encode(request(tool_turn(block), effort: "medium"))

      assert %{type: "redacted_thinking", data: "ENCRYPTED"} =
               Enum.at(body.messages, 1).content |> hd()
    end

    test "drops thinking when the request has no thinking enabled" do
      block = Message.reasoning(:anthropic, "I should read it.", signature: "sig123")
      body = Anthropic.encode(request(tool_turn(block), effort: nil))

      assert Enum.map(Enum.at(body.messages, 1).content, & &1.type) == ["text", "tool_use"]
      refute Map.has_key?(body, :thinking)
    end

    test "drops another provider's reasoning rather than signing it as its own" do
      block = Message.reasoning(:openai, "deepseek thought this", signature: nil)
      body = Anthropic.encode(request(tool_turn(block), effort: "medium"))

      assert Enum.map(Enum.at(body.messages, 1).content, & &1.type) == ["text", "tool_use"]
    end
  end

  describe "openai-compat" do
    defp chunk(delta), do: %{"choices" => [%{"delta" => delta}]}

    defp stream(deltas) do
      acc0 = %{
        text: "",
        reasoning: "",
        calls: %{},
        usage: Troupe.LLM.Provider.empty_usage(),
        finish: nil,
        model: "deepseek-v4-flash",
        reply_to: self(),
        ref: make_ref()
      }

      Enum.reduce(deltas, acc0, fn d, acc ->
        OpenAI.handle_event("x", Jason.encode!(chunk(d)), acc)
      end)
    end

    test "accumulates reasoning_content alongside a tool call" do
      acc =
        stream([
          %{"reasoning_content" => "The user wants "},
          %{"reasoning_content" => "mix.exs."},
          %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call_1",
                "function" => %{"name" => "read_file", "arguments" => ~s({"path":"mix.exs"})}
              }
            ]
          }
        ])

      assert acc.reasoning == "The user wants mix.exs."
    end

    test "the `reasoning` spelling is accepted too" do
      assert stream([%{"reasoning" => "thought"}]).reasoning == "thought"
    end

    test "reasoning goes back as a sibling of content, not a content block" do
      block = Message.reasoning(:openai, "The user wants mix.exs.")
      body = OpenAI.encode(request(tool_turn(block), model: "deepseek-v4-flash"))

      assistant = Enum.find(body.messages, &(&1.role == "assistant"))

      assert assistant.reasoning_content == "The user wants mix.exs."
      assert assistant.content == "Let me read it."
      assert [%{id: "call_1"}] = assistant.tool_calls
    end

    test "drops another provider's reasoning" do
      block = Message.reasoning(:anthropic, "claude thought this", signature: "sig")
      body = OpenAI.encode(request(tool_turn(block), model: "deepseek-v4-flash"))

      assistant = Enum.find(body.messages, &(&1.role == "assistant"))
      refute Map.has_key?(assistant, :reasoning_content)
    end

    test "an assistant turn with no reasoning carries no reasoning_content key" do
      body = OpenAI.encode(request(tool_turn(Message.text_block("plain"))))
      assistant = Enum.find(body.messages, &(&1.role == "assistant"))
      refute Map.has_key?(assistant, :reasoning_content)
    end
  end

  describe "neutral format" do
    test "reasoning is invisible to text and tool_uses" do
      blocks = [
        Message.reasoning(:openai, "thinking out loud"),
        Message.text_block("the answer"),
        Message.tool_use("c1", "read_file", %{})
      ]

      assert Message.text(blocks) == "the answer"
      assert [%{id: "c1"}] = Message.tool_uses(blocks)
      assert [%{type: :reasoning}] = Message.reasoning_of(blocks, :openai)
      assert Message.reasoning_of(blocks, :anthropic) == []
      assert Enum.map(Message.without_reasoning(blocks), & &1.type) == [:text, :tool_use]
    end

    test "survives the persisted-event round trip" do
      block = Message.reasoning(:anthropic, "thought", signature: "sig123")

      decoded =
        %{content: [block]}
        |> Jason.encode!()
        |> Jason.decode!()
        |> Troupe.Codec.decode_data()

      assert %{content: [%{type: :reasoning, provider: :anthropic, signature: "sig123"}]} = decoded
    end
  end
end
