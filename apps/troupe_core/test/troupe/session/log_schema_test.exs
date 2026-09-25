defmodule Troupe.Session.LogSchemaTest do
  @moduledoc """
  The published schema against what the session log actually writes.

  `protocol/schema/v1/` is a promise to people outside this repository, and a promise
  generated from a table in a module is only as good as its agreement with the code
  that emits the events. So a real session is run and every event it produced is
  checked against the schema its type claims.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Protocol.Schema

  test "every event a real session writes matches its published schema", context do
    %{session: session, fake: fake} =
      start_session(context,
        steps: [
          {:tools,
           [
             {"todo_write",
              %{"items" => [%{"id" => "a", "content" => "do it", "status" => "in_progress"}]}},
             {"write_file", %{"path" => "notes.md", "content" => "# notes\n"}}
           ]},
          {:text, "wrote the notes"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.set_goal(session.id, "the notes exist", nil, command_id: "c-goal")
    Troupe.send_input(session.id, "make some notes")
    await_state(session.id, [:idle, :done], 10_000)
    # One iteration that calls `goal_complete`, so every `loop_*` event is written.
    Fake.push(fake, [{:tools, [{"goal_complete", %{"summary" => "notes.md exists"}}]}])
    {:ok, _loop} = Troupe.start_loop(session.id, nil, max_iterations: 2, command_id: "c-loop")
    await_event(session.id, :loop_stopped, 10_000)
    Troupe.clear_goal(session.id)
    await_event(session.id, :goal_cleared)

    events = Troupe.events(session.id)
    assert length(events) > 5, "the session produced too little to be worth checking"
    assert Enum.any?(events, &(&1.type == "goal_set" and &1.data["command_id"] == "c-goal"))
    assert Enum.any?(events, &(&1.type == "loop_stopped" and &1.data["reason"] == "goal_complete"))

    for event <- events do
      assert Schema.validate_event(event.type, event.data) == :ok,
             "#{event.type} does not match its schema: " <>
               inspect(Schema.validate_event(event.type, event.data))
    end
  end

  test "every type the log wrote is a type the schema knows about", context do
    %{session: session} = start_session(context, steps: [{:text, "hello"}])

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "say hello")
    await_state(session.id, [:idle, :done], 10_000)

    known = Map.merge(Schema.events(), Schema.ephemeral_events())
    types = session.id |> Troupe.events() |> Enum.map(& &1.type) |> Enum.uniq()

    unknown = Enum.reject(types, &Map.has_key?(known, &1))

    assert unknown == [],
           "these event types are written but not published: #{inspect(unknown)}"
  end
end
