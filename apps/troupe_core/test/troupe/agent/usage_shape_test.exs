defmodule Troupe.Agent.UsageShapeTest do
  @moduledoc """
  What an agent counts of a prompt the cache served (Decision 657): the budget charges
  what was billed, the context gauge reads the prompt's whole length, and the log carries
  all four figures.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Server

  test "cache reads reach the log and the gauge but not the budget", context do
    steps = [
      {:text_and_tools, "one", [{"todo_read", %{}}]},
      {:text_and_tools, "two", [{"todo_read", %{}}]},
      {:text_and_tools, "done", [{"finish", %{"summary" => "ok"}}]}
    ]

    # Every answer bills 100 fresh input tokens and reports 1000 served from the cache.
    # A budget that counted the cache would be exhausted after the first turn.
    %{session: session} =
      start_session(context,
        steps: steps,
        cache_read: 1_000,
        config_overrides: [max_input_tokens: 1_000, context_window: 4_000]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: done}},
                   10_000

    assert done["reason"] == "finished"

    [first | _] = events_of_type(sid, :llm_response)

    assert first.data["usage"] ==
             %{"input_tokens" => 100, "output_tokens" => 1, "cache_read" => 1_000, "cache_write" => 0}

    %{"budget" => budget} = Server.summary(snapshot_state(sid), :done)
    assert budget["input_tokens"] == 300, "three turns of billed input"
    assert budget["headroom"]["context"]["used"] == 1_100, "the last prompt's whole length"
  end

  defp snapshot_state(sid) do
    pid = Troupe.Registry.agent_pid(sid, ["root"])
    {_state_name, state} = :sys.get_state(pid)
    state
  end
end
