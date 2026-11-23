defmodule Troupe.Session.CheckpointTest do
  @moduledoc """
  The checkpoint's contract (#1181): the facts a `checkpoint` carries, then the events after
  its `through`, fold to what the whole log folds to; and the facts are the fold of the log
  up to `through`. Held over generated logs, with checkpoints written where the session's
  writer would write them, and over the recorded logs in `test/fixtures/checkpoints/`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Troupe.Protocol.Event
  alias Troupe.Session.Checkpoint
  alias Troupe.Sessions.Fork

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "checkpoints"]))

  @agents [
    ["root"],
    ["root"],
    ["root"],
    ["root", "general#1"],
    ["root", "general#2"],
    ["root", "general#1", "explore#1"]
  ]
  @calls ["c1", "c2", "c3", "c4"]

  # A step of a session, and a number to pick its details by.
  @ops [
    :input,
    :llm,
    :llm,
    :tool,
    :approval,
    :decide,
    :question,
    :answer,
    :todo,
    :goal,
    :clear_goal,
    :delegate,
    :child_done,
    :compact,
    :compact,
    :rest,
    :rest,
    :cancel,
    :scratch,
    :warning,
    :error,
    :visibility,
    :loop,
    :taint,
    :switch,
    :done,
    :woken,
    :restarted
  ]

  property "the facts from any checkpoint plus the tail are the facts of the whole log" do
    check all(
            steps <- list_of(tuple({member_of(@ops), integer(0..1_000)}), max_length: 120),
            max_runs: 300
          ) do
      log = steps |> render() |> with_checkpoints()
      whole = log |> Checkpoint.fold_all() |> Checkpoint.facts()

      for checkpoint <- Enum.filter(log, &(&1.type == "checkpoint")) do
        assert_from(log, checkpoint, whole)
      end
    end
  end

  test "a log compacted and rested has its checkpoints, and they hold" do
    steps = [
      {:input, 0},
      {:llm, 1},
      {:approval, 2},
      {:compact, 3},
      {:rest, 4},
      {:input, 5},
      {:compact, 6},
      {:rest, 7}
    ]

    log = steps |> render() |> with_checkpoints()

    assert [first, second] = Enum.filter(log, &(&1.type == "checkpoint"))
    assert second.data["previous"] == first.seq
    whole = log |> Checkpoint.fold_all() |> Checkpoint.facts()
    assert_from(log, first, whole)
    assert_from(log, second, whole)
  end

  test "a checkpoint in a shape this build does not read is not started from" do
    event = %Event{type: "checkpoint", seq: 9, data: %{"shape" => "session/0", "through" => 8}}
    assert {:error, :unknown_shape} = Checkpoint.from_checkpoint(event)
  end

  describe "a recorded log" do
    for name <- ["manual", "threshold", "overflow", "background_approval"] do
      test "#{name}: from each checkpoint plus the tail is the whole, and each is the fold at through" do
        log = recorded(unquote(name))
        checkpoints = Enum.filter(log, &(&1.type == "checkpoint"))
        assert checkpoints != [], "the recording has its checkpoints in place"

        whole = log |> Checkpoint.fold_all() |> Checkpoint.facts()
        Enum.each(checkpoints, &assert_from(log, &1, whole))
      end
    end

    test "background_approval: the approval its child holds open is in the checkpoint" do
      [checkpoint | _] =
        "background_approval" |> recorded() |> Enum.filter(&(&1.type == "checkpoint"))

      assert [%{"agent" => [_root, _child]}] = checkpoint.data["facts"]["open_approvals"]
      assert [%{"wait" => false}] = checkpoint.data["facts"]["running"]
    end
  end

  describe "a fork" do
    test "moves what a carried checkpoint names with the rest, so it holds in the child" do
      parent = recorded("background_approval")
      {:ok, %{events: child}} = Fork.chain("s-parent", parent)
      child = Enum.map(child, &json/1)

      [before] = Enum.filter(parent, &(&1.type == "checkpoint"))
      [carried] = Enum.filter(child, &(&1.type == "checkpoint"))
      assert carried.data["through"] == before.data["through"] + 1
      assert carried.data["compacted"] == before.data["compacted"] + 1
      [approval] = carried.data["facts"]["open_approvals"]
      assert Enum.find(child, &(&1.seq == approval["seq"])).type == "approval_requested"

      whole = child |> Checkpoint.fold_all() |> Checkpoint.facts()
      assert_from(child, carried, whole)
    end

    test "moves the event a repair skipped" do
      parent = [
        sealed(1, "agent_started", %{"profile" => "build"}),
        sealed(2, "user_input", %{"text" => "unreadable"}),
        sealed(3, "log_repaired", %{"event" => 2, "by" => "user:a"})
      ]

      {:ok, %{events: [_forked | child]}} = Fork.chain("s-parent", parent)
      repaired = List.last(child)
      assert repaired.data["event"] == 3
      assert Enum.find(child, &(&1.seq == 3)).type == "user_input"
    end
  end

  defp sealed(seq, type, data), do: %Event{type: type, agent: ["root"], seq: seq, data: data}

  defp json(event), do: event |> Event.to_json() |> Jason.encode!() |> Jason.decode!() |> Event.from_json()

  defp assert_from(log, checkpoint, whole) do
    through = checkpoint.data["through"]
    at = log |> Enum.filter(&(&1.seq <= through)) |> Checkpoint.fold_all() |> Checkpoint.facts()
    assert checkpoint.data["facts"] == at, "the facts at #{through}"

    {:ok, start} = Checkpoint.from_checkpoint(checkpoint)
    tail = Enum.filter(log, &(&1.seq > through))

    assert tail |> Checkpoint.fold_all(start) |> Checkpoint.facts() == whole,
           "from #{checkpoint.seq}"
  end

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
  end

  # -- a generated session ----------------------------------------------------------

  # Where the writer writes: after a root rest that follows a compaction no checkpoint
  # covers. Through JSON, as everything a reader folds is.
  defp with_checkpoints(events) do
    {log, _fold, _seq} =
      Enum.reduce(events, {[], Checkpoint.new(), 0}, fn event, {log, fold, seq} ->
        event = disk(%{event | seq: seq + 1})
        fold = Checkpoint.fold(fold, event)

        if Checkpoint.rest?(event) and Checkpoint.owed?(fold) do
          checkpoint =
            disk(%Event{
              type: "checkpoint",
              agent: ["root"],
              seq: seq + 2,
              data: Checkpoint.data(fold)
            })

          {[checkpoint, event | log], Checkpoint.fold(fold, checkpoint), seq + 2}
        else
          {[event | log], fold, seq + 1}
        end
      end)

    Enum.reverse(log)
  end

  defp disk(event),
    do:
      %{event | ts: "2026-11-23T10:00:#{rem(event.seq, 60)}Z"}
      |> Event.to_json()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Event.from_json()

  defp render(steps) do
    opening = [
      ev("agent_started", ["root"], %{"profile" => "build", "bundle_version" => "v1"}),
      ev("session_created", ["root"], %{
        "profile" => "build",
        "kind" => "team",
        "visibility" => "team",
        "workspace" => "/w"
      })
    ]

    opening ++ Enum.flat_map(steps, &step/1)
  end

  defp step({op, n}), do: op |> events(n, pick(@agents, n), pick(@calls, n)) |> List.wrap()

  defp pick(list, n), do: Enum.at(list, rem(n, length(list)))

  defp ev(type, agent, data), do: %Event{type: type, agent: agent, data: data}

  defp events(:input, n, _agent, _call),
    do: [
      ev("input_accepted", ["root"], %{"command_id" => "in-#{n}"}),
      ev("user_input", ["root"], %{"text" => "go #{n}"})
    ]

  defp events(:llm, n, agent, _call) do
    usage = %{
      "input_tokens" => n,
      "cache_read" => rem(n, 7),
      "cache_write" => rem(n, 3),
      "output_tokens" => rem(n, 50)
    }

    gateway = if rem(n, 4) == 0, do: %{}, else: %{"cost_micros" => n * 10}

    [
      ev("llm_request", agent, %{"model" => "m"}),
      ev("llm_response", agent, %{"usage" => usage, "gateway" => gateway})
    ]
  end

  defp events(:tool, _n, agent, call),
    do: [
      ev("tool_call_started", agent, %{"call_id" => call, "name" => "read_file"}),
      ev("tool_call_completed", agent, %{"call_id" => call, "ok" => true})
    ]

  defp events(:approval, n, agent, call),
    do:
      ev("approval_requested", agent, %{
        "call_id" => call,
        "tool" => "shell",
        "args" => %{"command" => "ls #{n}"}
      })

  defp events(:decide, _n, agent, call),
    do: ev("approval_decided", agent, %{"call_id" => call, "decision" => "allow"})

  defp events(:question, n, agent, call),
    do:
      ev("question_asked", agent, %{
        "call_id" => "q-" <> call,
        "question" => "which #{n}?",
        "options" => []
      })

  defp events(:answer, n, _agent, call) do
    type = pick(["question_answered", "budget_ask_answered", "tool_failures_ask_answered"], n)
    ev(type, ["root"], %{"call_id" => "q-" <> call, "text" => "this"})
  end

  defp events(:todo, n, _agent, _call),
    do:
      ev("todo_updated", ["root"], %{
        "items" => [%{"id" => "t#{n}", "content" => "step #{n}", "status" => "in_progress"}]
      })

  defp events(:goal, n, _agent, _call), do: ev("goal_set", ["root"], %{"text" => "reach #{n}"})
  defp events(:clear_goal, _n, _agent, _call), do: ev("goal_cleared", ["root"], %{})

  defp events(:delegate, n, _agent, call) do
    child = pick([["root", "general#1"], ["root", "general#2"]], n)

    [
      ev("delegation_started", ["root"], %{
        "call_id" => call,
        "agent" => "general",
        "child_path" => child,
        "task" => "look",
        "wait" => rem(n, 2) == 0
      }),
      ev("agent_started", child, %{"profile" => "general"})
    ]
  end

  defp events(:child_done, n, _agent, call) do
    child = pick([["root", "general#1"], ["root", "general#2"]], n)

    [
      ev("agent_done", child, %{"reason" => "finished"}),
      ev("tool_call_completed", ["root"], %{"call_id" => call, "ok" => true})
    ]
  end

  defp events(:compact, n, _agent, _call) do
    usage = %{"input_tokens" => n, "output_tokens" => 3}

    ev("compacted", ["root"], %{
      "summary" => "summary #{n}",
      "reason" => "threshold",
      "usage" => usage,
      "gateway" => %{"cost_micros" => 5}
    })
  end

  defp events(:rest, n, _agent, _call),
    do: ev("turn_ended", ["root"], %{"turn" => %{"calls" => 1, "unpriced" => rem(n, 2)}})

  defp events(:cancel, n, agent, _call),
    do: ev("cancelled", agent, %{"turn" => %{"calls" => 1, "unpriced" => rem(n, 2)}})

  defp events(:scratch, n, _agent, _call),
    do:
      ev("scratch_updated", ["root"], %{
        "name" => pick(["plan.md", "notes.md"], n),
        "version" => n,
        "kind" => "markdown"
      })

  defp events(:warning, n, _agent, _call),
    do:
      ev("budget_warning", ["root"], %{
        "dimension" => pick(["turns", "input", "wall", "context"], n),
        "limit" => n
      })

  defp events(:error, n, agent, _call), do: ev("llm_error", agent, %{"reason" => "failed #{n}"})

  defp events(:visibility, n, _agent, _call),
    do:
      ev("session_visibility_changed", ["root"], %{"visibility" => pick(["team", "private"], n)})

  defp events(:loop, n, _agent, _call) do
    id = "loop-#{rem(n, 2)}"

    pick(
      [
        ev("loop_started", ["root"], %{"loop_id" => id, "goal" => "g", "max_iterations" => 5}),
        ev("loop_iteration_started", ["root"], %{"loop_id" => id, "iteration" => rem(n, 5)}),
        ev("loop_iteration_finished", ["root"], %{
          "loop_id" => id,
          "iteration" => rem(n, 5),
          "outcome" => "continue"
        }),
        ev("loop_stopped", ["root"], %{
          "loop_id" => id,
          "reason" => "requested",
          "iterations" => 2
        })
      ],
      n
    )
  end

  defp events(:taint, n, _agent, _call),
    do:
      ev("session_tainted", ["root"], %{
        "kind" => "personal_connector",
        "tools" => ["t#{n}"],
        "actor" => "user:a"
      })

  defp events(:switch, n, agent, _call),
    do: ev("profile_switched", agent, %{"from" => "build", "to" => pick(["plan", "build"], n)})

  defp events(:done, n, agent, _call),
    do:
      ev("agent_done", agent, %{
        "reason" => pick(["finished", "budget_exhausted"], n),
        "limit" => "max_turns"
      })

  defp events(:woken, _n, agent, _call), do: ev("agent_woken", agent, %{"from" => "finished"})

  defp events(:restarted, n, _agent, _call),
    do:
      ev("agent_restarted", ["root"], %{"interrupted" => rem(n, 2) == 0, "replayed_events" => n})
end
