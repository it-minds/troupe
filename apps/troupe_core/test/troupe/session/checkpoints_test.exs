defmodule Troupe.Session.CheckpointsTest do
  @moduledoc """
  The session's checkpoint writer (#1181): one `checkpoint` after each root compaction, at
  the root's next rest, whose facts are the fold of the log up to the rest it names.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.{Checkpoint, Log}

  test "a compaction in the middle of a turn is checkpointed at the turn's end, once", context do
    %{session: session} =
      start_session(context,
        config_overrides: [context_window: 120, compact_at: 0.5],
        steps: [
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"todo_read", %{}}]},
          {:text, "the summary"},
          {:text, "carrying on"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "do several things")
    checkpoint = await_event(session.id, "checkpoint", 10_000)

    events = Troupe.events(session.id)
    [compacted | _] = Enum.filter(events, &(&1.type == "compacted"))
    rest = Enum.find(events, &(&1.seq == checkpoint.data["through"]))

    assert checkpoint.agent == ["root"]
    assert checkpoint.data["shape"] == "session/1"
    assert checkpoint.data["compacted"] == compacted.seq
    assert checkpoint.data["previous"] == nil
    assert checkpoint.data["summary"] == compacted.data["summary"]
    # When the summary was made, beside the checkpoint's own time at the rest after it.
    assert checkpoint.data["compacted_at"] == compacted.ts
    assert is_binary(checkpoint.ts) and checkpoint.seq > compacted.seq

    assert is_integer(compacted.data["folded_through"]) and
             compacted.data["folded_through"] < compacted.seq

    # Not mid-turn: the root's rest after the compaction, and nothing of the turn after it.
    assert rest.type == "turn_ended" and rest.agent == ["root"]
    assert rest.seq > compacted.seq

    assert checkpoint.data["facts"] == facts_through(events, rest.seq)
    assert [_one] = Enum.filter(events, &(&1.type == "checkpoint"))
  end

  test "each compaction a person asks for gets its own, naming the one before", context do
    %{session: session} =
      start_session(context,
        steps: [
          {:text, "one"},
          {:text, "two"},
          {:text, "three"},
          {:text, "four"},
          {:text, "summary one"},
          {:text, "five"},
          {:text, "six"},
          {:text, "summary two"}
        ]
      )

    # Three turns are what a compaction keeps, so four come before each.
    Troupe.subscribe(session.id)
    Enum.each(["first", "second", "third", "fourth"], &turn(session.id, &1))
    assert :ok = Troupe.compact(session.id, nil, command_id: "c-1")
    first = await_event(session.id, "checkpoint", 10_000)
    Enum.each(["fifth", "sixth"], &turn(session.id, &1))
    assert :ok = Troupe.compact(session.id, nil, command_id: "c-2")
    second = await_event(session.id, "checkpoint", 10_000)

    assert second.data["previous"] == first.seq
    assert second.data["compacted"] > first.seq
    assert second.data["summary"] == "summary two"

    events = Troupe.events(session.id)
    assert second.data["facts"] == facts_through(events, second.data["through"])
    assert length(Enum.filter(events, &(&1.type == "checkpoint"))) == 2
  end

  test "a compaction a crash left without one is checkpointed when the root next rests",
       context do
    %{session: session} = start_session(context, steps: [{:text, "hello"}])
    Troupe.subscribe(session.id)
    turn(session.id, "hi")

    # The writer is down, as it is when the tree goes between the compaction and the rest.
    stop_writer(session.id)

    {:ok, compacted} =
      Log.append(session.id, ["root"], :compacted, %{
        "summary" => "earlier",
        "reason" => "threshold"
      })

    {:ok, _} = Log.append(session.id, ["root"], :llm_request, %{"model" => "fake-model"})

    # It comes back mid-turn: nothing owed yet.
    restart_writer(session.id)
    refute Enum.any?(Troupe.events(session.id), &(&1.type == "checkpoint"))

    {:ok, rest} = Log.append(session.id, ["root"], :turn_ended, %{})
    checkpoint = await_event(session.id, "checkpoint")
    assert checkpoint.data["through"] == rest
    assert checkpoint.data["compacted"] == compacted

    # And a tree that comes back with the rest already written writes it at once.
    stop_writer(session.id)
    {:ok, again} = Log.append(session.id, ["root"], :compacted, %{"summary" => "later"})
    {:ok, rested} = Log.append(session.id, ["root"], :turn_ended, %{})
    restart_writer(session.id)
    checkpoint = await_event(session.id, "checkpoint")
    assert checkpoint.data["compacted"] == again
    assert checkpoint.data["through"] == rested
    assert checkpoint.data["facts"] == facts_through(Troupe.events(session.id), rested)
  end

  test "a rest with nothing compacted since writes none", context do
    %{session: session} = start_session(context, steps: [{:text, "a"}, {:text, "b"}])
    Troupe.subscribe(session.id)
    turn(session.id, "one")
    turn(session.id, "two")
    # The writer has seen both rests by the time it answers.
    _ = :sys.get_state(Troupe.Registry.checkpoints(session.id))
    refute Enum.any?(Troupe.events(session.id), &(&1.type == "checkpoint"))
  end

  defp facts_through(events, through),
    do: events |> Enum.filter(&(&1.seq <= through)) |> Checkpoint.fold_all() |> Checkpoint.facts()

  # A turn from what is sent now: what came before it is let go first.
  defp turn(session_id, text) do
    flush()
    Troupe.send_input(session_id, text)
    await_event(session_id, "turn_ended", 10_000)
    await_state(session_id, [:idle], 10_000)
  end

  defp flush do
    receive do
      {:troupe_event, _sid, _event} -> flush()
    after
      0 -> :ok
    end
  end

  defp stop_writer(session_id) do
    sup = Troupe.Registry.session(session_id)
    :ok = Supervisor.terminate_child(sup, Troupe.Session.Checkpoints)
  end

  defp restart_writer(session_id) do
    sup = Troupe.Registry.session(session_id)
    {:ok, _pid} = Supervisor.restart_child(sup, Troupe.Session.Checkpoints)
    _ = :sys.get_state(Troupe.Registry.checkpoints(session_id))
  end
end
