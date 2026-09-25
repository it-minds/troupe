defmodule Troupe.Agent.TurnEndedTest do
  @moduledoc """
  The end of a turn, written down (issue #127). A turn that comes to rest ends with
  `turn_ended` in the log, after whatever ended it; a finished agent ends with
  `agent_done` instead. The live `agent_state` says the same thing, but it is ephemeral:
  a client that was not listening, or whose copy was dropped, reads the rest from here.
  """

  use Troupe.SessionCase, async: true

  defp run(context, steps) do
    %{session: session} = start_session(context, steps: steps)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    session.id
  end

  test "a reply with no tool call ends the turn, and the log says so after the reply", context do
    sid = run(context, [{:text, "the answer"}])
    await_state(sid, [:idle], 10_000)

    assert ["llm_response", "turn_ended"] = sid |> event_types() |> Enum.take(-2)
    assert [%Event{agent: ["root"], data: data}] = events_of_type(sid, :turn_ended)
    assert data == %{}
    assert events_of_type(sid, :agent_done) == []
  end

  test "a failed model request ends the turn, after the error that says why", context do
    sid = run(context, [{:error, "the gateway is down"}])
    await_state(sid, [:idle], 10_000)

    assert ["llm_error", "turn_ended"] = sid |> event_types() |> Enum.take(-2)
  end

  test "an agent that finishes is done, not at the end of a turn", context do
    sid = run(context, [{:tools, [{"finish", %{"summary" => "all done"}}]}])
    await_state(sid, [:done], 10_000)

    assert [_done] = events_of_type(sid, :agent_done)
    assert events_of_type(sid, :turn_ended) == []
  end
end
