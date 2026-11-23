defmodule Troupe.Session.CheckpointRecordingsTest do
  @moduledoc """
  How `test/fixtures/checkpoints/` was recorded: sessions run against the scripted model,
  each log copied as the session wrote it, checkpoints in place. Run only when asked
  (`TROUPE_RECORD_CHECKPOINTS=1 mix test test/troupe/session/checkpoint_recordings_test.exs`
  in `apps/troupe_core`), since a recording is a fixture other suites read and is changed on
  purpose, never by a test run.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Log

  @into Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "checkpoints"]))

  if System.get_env("TROUPE_RECORD_CHECKPOINTS") do
    test "manual: two compactions a person asked for, with a goal and a task list", context do
      todo = %{"items" => [%{"id" => "a", "content" => "read it", "status" => "in_progress"}]}

      %{session: session} =
        start_session(context,
          steps: [
            {:text, "one"},
            {:tools, [{"todo_write", todo}]},
            {:text, "two"},
            {:text, "three"},
            {:text, "four"},
            {:text, "summary one"},
            {:text, "five"},
            {:text, "six"},
            {:text, "summary two"},
            {:text, "seven"}
          ]
        )

      sid = session.id
      Troupe.subscribe(sid)
      :ok = Troupe.set_goal(sid, "keep the tests green")
      Enum.each(["first", "second", "third", "fourth"], &turn(sid, &1))
      :ok = Troupe.compact(sid, nil, command_id: "c-1")
      await_event(sid, "checkpoint", 10_000)
      Enum.each(["fifth", "sixth"], &turn(sid, &1))
      :ok = Troupe.compact(sid, nil, command_id: "c-2")
      await_event(sid, "checkpoint", 10_000)
      turn(sid, "seventh")
      record(sid, "manual")
    end

    test "threshold: a compaction in the middle of a turn, checkpointed at its end", context do
      %{session: session} =
        start_session(context,
          config_overrides: [context_window: 120, compact_at: 0.5],
          steps: [
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]},
            {:text, "the summary"},
            {:text, "carrying on"},
            {:text, "and again"}
          ]
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "do several things")
      await_event(sid, "checkpoint", 10_000)
      turn(sid, "again")
      record(sid, "threshold")
    end

    test "overflow: a prompt the provider refused, compacted and sent again", context do
      write_file(context, "big.txt", Enum.map_join(1..80, "\n", &"line #{&1}"))

      %{session: session} =
        start_session(context,
          steps: [
            {:text, "first answer"},
            {:text, "second answer"},
            {:tools, [{"read_file", %{"path" => "big.txt"}}]},
            {:text, "read it"},
            {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}},
            {:text, "summary of the first turns"},
            {:text, "carried on"},
            {:text, "and on"}
          ]
        )

      sid = session.id
      Troupe.subscribe(sid)
      Enum.each(["first", "second", "read big.txt"], &turn(sid, &1))
      Troupe.send_input(sid, "carry on")
      await_event(sid, "checkpoint", 10_000)
      turn(sid, "and on")
      record(sid, "overflow")
    end

    test "background_approval: a child in the background holds an approval open across it",
         context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          routes: %{
            "root" => [
              {:text, "one"},
              {:text, "two"},
              {:text, "three"},
              {:tools, [{"delegate", brief("general", "ask for it", %{"wait" => false})}]},
              {:text, "resting while it asks"},
              {:text, "the summary"},
              {:text, "it has finished"}
            ],
            "general" => [
              {:tools, [{"needs_approval", %{"note" => "child"}}]},
              {:tools, [{"finish", finished("asked")}]}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Enum.each(["first", "second", "third"], &turn(sid, &1))
      flush()
      Troupe.send_input(sid, "start it in the background")
      held = await_child_approval(sid)
      ["root", "general#1"] = held.agent
      await_turn_ended(sid, ["root"])
      await_state(sid, [:idle], 10_000)

      :ok = Troupe.compact(sid, nil, command_id: "c-1")
      await_event(sid, "checkpoint", 10_000)

      flush()
      Troupe.approve(sid, held.data["call_id"], :allow)
      await_turn_ended(sid, ["root"])
      record(sid, "background_approval")
    end
  end

  # A turn from what is sent now: what came before it is let go first.
  defp turn(sid, text) do
    flush()
    Troupe.send_input(sid, text)
    await_turn_ended(sid, ["root"])
    await_state(sid, [:idle], 10_000)
  end

  defp await_turn_ended(sid, agent) do
    case await_event(sid, "turn_ended", 10_000) do
      %{agent: ^agent} -> :ok
      _other -> await_turn_ended(sid, agent)
    end
  end

  # The approval a child asked for, the root's own allowed as they come.
  defp await_child_approval(sid) do
    case await_event(sid, :approval_requested, 10_000) do
      %{agent: ["root"]} = own ->
        Troupe.approve(sid, own.data["call_id"], :allow)
        await_child_approval(sid)

      held ->
        held
    end
  end

  defp flush do
    receive do
      {:troupe_event, _sid, _event} -> flush()
    after
      0 -> :ok
    end
  end

  # The log as the session wrote it, once its writer has seen the last of it.
  defp record(sid, name) do
    _ = :sys.get_state(Troupe.Registry.checkpoints(sid))
    File.mkdir_p!(@into)
    File.cp!(Log.path(sid), Path.join(@into, name <> ".jsonl"))
  end
end
