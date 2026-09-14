defmodule Troupe.Agent.LoopTest do
  use Troupe.SessionCase, async: true

  describe "single-agent loop" do
    test "reads a file, edits it, and answers", context do
      write_file(context, "lib/math.ex", "defmodule Math do\n  def answer, do: 0\nend\n")

      %{session: session} =
        start_session(context,
          steps: [
            {:tools, [{"read_file", %{"path" => "lib/math.ex"}}]},
            {:tools,
             [
               {"edit_file",
                %{
                  "path" => "lib/math.ex",
                  "old_string" => "def answer, do: 0",
                  "new_string" => "def answer, do: 42"
                }}
             ]},
            {:text, "Changed the answer to 42."}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "make answer return 42")
      await_state(session.id, [:idle])

      assert read_file(context, "lib/math.ex") =~ "def answer, do: 42"

      types = event_types(session.id)

      # `session_created` is the first durable event now: it is what lets a listing —
      # and a dormant session — be rebuilt from the log alone. `input_accepted` carries
      # the author and the client's own `command_id`, and comes before the content so an
      # optimistic render reconciles before it has anything to reconcile against.
      assert [
               "agent_started",
               "session_created",
               "input_accepted",
               "user_input",
               "llm_request",
               "llm_response",
               "tool_call_started",
               "tool_call_completed",
               "tool_results",
               "llm_request",
               "llm_response",
               "tool_call_started",
               "tool_call_completed",
               "tool_results",
               "llm_request",
               "llm_response"
             ] == types
    end

    test "a tool that fails yields an error result the model can read", context do
      %{session: session} =
        start_session(context,
          steps: [
            {:tools, [{"read_file", %{"path" => "does/not/exist.ex"}}]},
            {:text, "That file is missing."}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "read a missing file")
      await_state(session.id, [:idle])

      [completed] = events_of_type(session.id, "tool_call_completed")
      refute completed.data["ok"]
      assert completed.data["content"] =~ "No such file"
    end
  end

  describe "parallelism" do
    test "three 500ms tool calls in one turn finish in well under a second", context do
      %{session: session} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"shell", %{"command" => "sleep 0.5; echo one"}},
               {"shell", %{"command" => "sleep 0.5; echo two"}},
               {"shell", %{"command" => "sleep 0.5; echo three"}}
             ]},
            {:text, "all done"}
          ]
        )

      Troupe.subscribe(session.id)

      Troupe.send_input(session.id, "run three things")
      await_state(session.id, [:idle], 10_000)

      started_events = events_of_type(session.id, "tool_call_started")
      completed = events_of_type(session.id, "tool_call_completed")

      assert length(started_events) == 3
      assert length(completed) == 3
      assert Enum.all?(completed, & &1.data["ok"])

      # The claim is that the three calls overlap, and the event timestamps say so
      # directly: the last of them started before the first of them finished, so there
      # was an instant at which all three were in flight. Serial execution cannot
      # produce that ordering however slow the machine is.
      #
      # This used to be a stopwatch — three 500ms calls inside a 1000ms budget — which
      # says the same thing only on an idle machine. It failed at 2041ms on a runner
      # where a single 500ms call no longer cost 500ms either, and that is a fact about
      # the runner rather than about the loop.
      last_start = started_events |> Enum.map(&timestamp/1) |> Enum.max(DateTime)
      first_finish = completed |> Enum.map(&timestamp/1) |> Enum.min(DateTime)

      assert DateTime.before?(last_start, first_finish),
             "the calls ran one after another: the last started at " <>
               "#{DateTime.to_iso8601(last_start)}, the first finished at " <>
               "#{DateTime.to_iso8601(first_finish)}"
    end
  end

  defp timestamp(event) do
    {:ok, at, _offset} = DateTime.from_iso8601(event.ts)
    at
  end
end
