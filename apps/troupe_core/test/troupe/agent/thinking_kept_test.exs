defmodule Troupe.Agent.ThinkingKeptTest do
  @moduledoc """
  One of Anthropic's newest models thinks whether or not it is asked to, and what it
  thought goes back to it within the turn (#427, Decision 805): an agent's tool-use turn on
  Claude Opus 5.5 with no `reasoning_effort`, against a loopback stand-in that records each
  body, sends the second call the thinking block the first one returned, signature and all,
  and asks for no thinking itself.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Test.ErrorStandIn

  test "the second call of a tool-use turn carries the first call's thinking", context do
    write_file(context, "notes.txt", "a tab is two spaces\n")

    stand_in =
      ErrorStandIn.start(
        script: fn
          1, _body -> {:thinking_tool, "sig-opus-1", "read_file", %{"path" => "notes.txt"}}
          _n, _body -> {:text, "done"}
        end
      )

    on_exit(fn -> ErrorStandIn.stop(stand_in) end)

    %{session: session} =
      start_session(context,
        config_overrides: [
          provider: "anthropic",
          model: "claude-opus-5-5",
          base_url: stand_in.base_url,
          api_key: "sk-stand-in-0123456789abcdef"
        ]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "read notes.txt")
    await_state(sid, [:idle], 15_000)

    assert events_of_type(sid, "llm_error") == []
    assert [{1, "/v1/messages", first}, {2, "/v1/messages", second}] = ErrorStandIn.drain()

    for body <- [first, second] do
      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "output_config")
    end

    assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))

    assert [
             %{"type" => "thinking", "thinking" => "", "signature" => "sig-opus-1"},
             %{"type" => "tool_use", "id" => "toolu_1", "input" => %{"path" => "notes.txt"}}
           ] = assistant["content"]
  end
end
