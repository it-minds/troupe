defmodule Troupe.LLM.ReasoningTest do
  @moduledoc "A reasoning block is opaque, provider-bound, invisible to prose, and survives the log (Decision 658)."

  use ExUnit.Case, async: true

  alias Troupe.LLM.{Message, Reasoning, Text, ToolUse}

  test "reasoning is invisible to text and tool_uses, and found only by its provider" do
    message =
      Message.assistant([
        %Reasoning{provider: :openai, text: "thinking out loud"},
        %Text{text: "the answer"},
        %ToolUse{id: "c1", name: "read_file", input: %{}}
      ])

    assert Message.text(message) == "the answer"
    assert [%ToolUse{id: "c1"}] = Message.tool_uses(message)
    assert [%Reasoning{text: "thinking out loud"}] = Message.reasoning_of(message, :openai)
    assert Message.reasoning_of(message, :anthropic) == []
    assert [%Text{}, %ToolUse{}] = Message.without_reasoning(message).content
  end

  test "survives the log round trip, and a provider this build does not know still replays" do
    block = %Reasoning{provider: :anthropic, text: "thought", signature: "sig123"}
    redacted = %Reasoning{provider: :anthropic, text: "ENCRYPTED", redacted: true}
    message = Message.assistant([block, redacted, %Text{text: "hi"}])

    assert message |> Message.to_json() |> Jason.encode!() |> Jason.decode!() |> Message.from_json() ==
             message

    json = %{
      "role" => "assistant",
      "content" => [%{"type" => "reasoning", "provider" => "a_provider_no_build_has", "text" => "t"}]
    }

    assert %Message{content: [%Reasoning{provider: :unknown, text: "t"}]} = Message.from_json(json)
  end
end
