defmodule Troupe.Agent.ReasoningShapeTest do
  @moduledoc """
  A model's thinking reaches the live stream under its own kind and the log as a block,
  and stays out of the prose (Decision 658).
  """

  use Troupe.SessionCase, async: true

  test "thinking is streamed as a reasoning delta, logged as a block, and kept out of the summary",
       context do
    steps = [{:reasoning, "let me think", {:text_and_tools, "done", [{"finish", %{"summary" => "ok"}}]}}]

    %{session: session} = start_session(context, steps: steps)
    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")

    assert_receive {:troupe_event, ^sid,
                    %Event{type: "llm_delta", data: %{"kind" => "reasoning", "text" => text}}},
                   10_000

    assert text =~ "let me"

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: done}},
                   10_000

    assert done["reason"] == "finished"
    assert done["summary"] == "ok"

    [response] = events_of_type(sid, :llm_response)

    assert [
             %{"type" => "reasoning", "provider" => "fake", "text" => "let me think"},
             %{"type" => "text", "text" => "done"},
             %{"type" => "tool_use"}
           ] = response.data["message"]["content"]
  end
end
