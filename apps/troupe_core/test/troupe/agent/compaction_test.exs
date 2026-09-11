defmodule Troupe.Agent.CompactionTest do
  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Message

  test "crossing the context threshold summarises older turns and keeps working", context do
    # A tiny window so the fake's reported usage crosses the threshold immediately.
    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: [context_window: 120, compact_at: 0.5],
        steps: [
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"todo_read", %{}}]},
          {:text, "here is a summary of everything that happened earlier"},
          {:text, "carrying on"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "do several things")
    await_state(session.id, [:idle], 10_000)

    # Which scripted answer the summariser consumes depends on how many turns ran
    # before the threshold was crossed, so the assertion is on the shape: a summary
    # was produced, and it came from the summariser call.
    assert [compacted | _] = events_of_type(session.id, "compacted")
    assert is_binary(compacted.data["summary"])
    assert compacted.data["summary"] != ""

    conversation = Troupe.snapshot(session.id).conversation

    # The summary replaced the older turns rather than being appended to them.
    assert length(conversation) < 8
    assert Enum.any?(conversation, &(Message.text(&1) =~ "Summary of earlier work"))

    # The summariser call carries the summariser system prompt, not the agent's.
    summariser =
      fake
      |> Fake.requests()
      |> Enum.find(&(&1.system =~ "compress a coding session"))

    assert summariser, "expected a summariser request"
    assert summariser.tools == []
  end

  test "nothing old enough to summarise does not loop", context do
    %{session: session} =
      start_session(context,
        config_overrides: [context_window: 10, compact_at: 0.1],
        steps: [{:text, "short answer"}, {:text, "another"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hi")
    await_state(session.id, [:idle], 10_000)

    # With a two-message conversation there is nothing to drop, so the agent must
    # settle rather than compact repeatedly.
    assert events_of_type(session.id, "compacted") == []
    assert Troupe.snapshot(session.id).state == :idle
  end
end
