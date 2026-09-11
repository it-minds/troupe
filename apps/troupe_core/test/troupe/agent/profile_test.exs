defmodule Troupe.Agent.ProfileTest do
  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Message
  alias Troupe.Todo

  describe "profiles" do
    test "plan rejects writes and shell without running them", context do
      write_file(context, "lib/a.ex", "original\n")

      %{session: session} =
        start_session(context,
          agent: "plan",
          steps: [
            {:tools,
             [
               {"write_file", %{"path" => "lib/a.ex", "content" => "clobbered"}},
               {"shell", %{"command" => "echo nope > lib/a.ex"}},
               {"read_file", %{"path" => "lib/a.ex"}}
             ]},
            {:text, "I can only read here."}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "change the file")
      await_state(session.id, [:idle])

      results = events_of_type(session.id, "tool_call_completed")
      by_name = Map.new(results, &{&1.data["name"], &1.data})

      refute by_name["write_file"]["ok"]
      refute by_name["shell"]["ok"]
      assert by_name["read_file"]["ok"]

      # The rejection happened before the tool, not inside it.
      assert read_file(context, "lib/a.ex") == "original\n"
    end

    test "switching to build carries the conversation and todos and changes the tool set",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          agent: "plan",
          steps: [
            {:tools,
             [
               {"todo_write",
                %{"items" => [%{"id" => "t1", "content" => "do the work", "status" => "pending"}]}}
             ]},
            {:text, "Here is the plan."},
            {:text, "Executing."}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "plan the work")
      await_state(session.id, [:idle])

      plan_request = fake |> Fake.requests() |> List.first()
      plan_tools = Enum.map(plan_request.tools, & &1.name)
      refute "write_file" in plan_tools
      refute "shell" in plan_tools

      Troupe.switch_profile(session.id, "build")
      await_event(session.id, :profile_switched)

      Troupe.send_input(session.id, "now build it")
      await_state(session.id, [:idle])

      build_request = fake |> Fake.requests() |> List.last()
      build_tools = Enum.map(build_request.tools, & &1.name)
      assert "write_file" in build_tools
      assert "shell" in build_tools

      # The conversation survived the switch, and the todo list rides in the system
      # prompt so the build agent sees what the plan agent decided.
      assert length(build_request.messages) >= 4
      assert build_request.system =~ "do the work"
      assert Troupe.snapshot(session.id).profile == "build"
    end

    test "a switch requested mid-turn is applied at the turn boundary", context do
      %{session: session} =
        start_session(context,
          agent: "plan",
          delay_ms: 150,
          steps: [{:text, "still planning"}, {:text, "building now"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "start")

      # Sent while the model call is in flight, so it is postponed rather than
      # applied to the turn already running.
      await_event(session.id, :llm_request)
      Troupe.switch_profile(session.id, "build")

      await_state(session.id, [:idle])
      await_event(session.id, :profile_switched)

      assert Troupe.snapshot(session.id).profile == "build"
    end
  end

  describe "definition overrides" do
    test "a project explore.md overrides the built-in and still cannot write", context do
      write_file(context, ".troupe/agents/explore.md", """
      ---
      description: project explore
      mode: subagent
      tools:
        - read_file
        - grep
        - finish
      ---
      Project explore prompt.
      """)

      write_file(context, "lib/keep.ex", "untouched\n")

      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "explore", "task" => "look around"}}]},
              {:text, "explored"}
            ],
            "explore" => [
              {:tools, [{"write_file", %{"path" => "lib/keep.ex", "content" => "clobbered"}}]},
              {:tools, [{"finish", %{"summary" => "I cannot write."}}]}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "explore")
      await_state(session.id, [:idle], 10_000)

      explore_request = fake |> Fake.requests_for("explore") |> List.first()
      assert explore_request.system =~ "Project explore prompt."
      refute "write_file" in Enum.map(explore_request.tools, & &1.name)

      rejected =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.find(&(&1.data["name"] == "write_file"))

      refute rejected.data["ok"]
      assert read_file(context, "lib/keep.ex") == "untouched\n"
    end
  end

  describe "task list" do
    test "two in_progress items are rejected with a readable error", context do
      %{session: session} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"todo_write",
                %{
                  "items" => [
                    %{"id" => "a", "content" => "one", "status" => "in_progress"},
                    %{"id" => "b", "content" => "two", "status" => "in_progress"}
                  ]
                }}
             ]},
            {:text, "understood"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "plan badly")
      await_state(session.id, [:idle])

      [completed] = events_of_type(session.id, "tool_call_completed")
      refute completed.data["ok"]
      assert completed.data["content"] =~ "in progress at a time"
      assert Troupe.snapshot(session.id).todos == []
    end

    test "a TUI cancel shows up in the agent's next request", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"todo_write",
                %{
                  "items" => [
                    %{"id" => "a", "content" => "keep this", "status" => "pending"},
                    %{"id" => "b", "content" => "drop this", "status" => "pending"}
                  ]
                }}
             ]},
            {:text, "list written"},
            {:text, "acknowledged"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "write a list")
      await_state(session.id, [:idle])

      Troupe.send_input(session.id, Todo.Edit.cancel("b"), :tui_todo_edit)
      await_state(session.id, [:idle])

      last = fake |> Fake.requests() |> List.last()

      # The change reaches the model twice over: as a user message saying what the
      # human did, and in the task list carried in the system prompt.
      assert Enum.any?(last.messages, &(Message.text(&1) =~ "cancelled task b"))
      assert last.system =~ "[-] [b] drop this"

      todos = Troupe.snapshot(session.id).todos
      assert Enum.find(todos, &(&1.id == "b")).status == :cancelled
      assert Enum.find(todos, &(&1.id == "a")).status == :pending
    end
  end
end
