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
      # and a dormant session — be rebuilt from the log alone.
      assert [
               "agent_started",
               "session_created",
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

      started = System.monotonic_time(:millisecond)
      Troupe.send_input(session.id, "run three things")
      await_state(session.id, [:idle], 10_000)
      elapsed = System.monotonic_time(:millisecond) - started

      completed = events_of_type(session.id, "tool_call_completed")
      assert length(completed) == 3
      assert Enum.all?(completed, & &1.data["ok"])

      # Serial execution would take at least 1500ms; the concurrency budget is the
      # 500ms of real work plus process and log overhead.
      assert elapsed < 1_000, "three concurrent 500ms calls took #{elapsed}ms"
    end
  end
end
