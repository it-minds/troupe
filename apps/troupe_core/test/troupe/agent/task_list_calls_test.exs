defmodule Troupe.Agent.TaskListCallsTest do
  @moduledoc """
  A small task takes no model calls for a task list (issue #428, Decision 793).

  The live bench's `follow_steps` (three steps read from a file), run offline by the
  bench's runner under a live run's 12-call cap, against a stand-in that answers as
  `qwen3-235b` did in the live bench: one tool call in each response, never two, and a
  task list whenever `todo_write` is offered, written after reading the steps and updated
  as each is done, each `todo_write` in a response of its own. Its other calls are the
  ones the model made in the runs: the file read, each step's work, and three reads to
  check it.

  It goes by the tool alone, as the model did. Told to write a list for "more than a few
  steps", and then for "more than five steps" with "for five or fewer, do the work without
  one", it wrote one for this task of three in every run, six of six, and updated it after
  each step.
  """

  use ExUnit.Case, async: false

  alias Troupe.Bench.{LiveScenarios, Runner}
  alias Troupe.LLM.{Message, Request, ToolUse}
  alias Troupe.Protocol.Event

  @moduletag :tmp_dir

  # TASK.md's steps.
  @steps 3

  # What the model did in every run, the task list aside, in order.
  @work [
    {"read_file", %{"path" => "TASK.md"}},
    {"write_file", %{"path" => "out/greeting.txt", "content" => "hello from the bench\n"}},
    {"read_file", %{"path" => "config.ini"}},
    {"edit_file",
     %{"path" => "config.ini", "old_string" => "mode = draft", "new_string" => "mode = final"}},
    {"write_file", %{"path" => "out/done.txt", "content" => "out/greeting.txt\nconfig.ini\n"}},
    {"list_files", %{"path" => "out"}},
    {"read_file", %{"path" => "config.ini"}},
    {"read_file", %{"path" => "out/done.txt"}}
  ]

  # The calls of `@work`, counted from one, after which each step is done.
  @step_done_after [2, 4, 5]

  test "three steps from a file take no todo_write call: nine model calls, under the cap",
       %{tmp_dir: dir} do
    [follow_steps] = Enum.filter(LiveScenarios.all(), &(&1.name == "follow_steps"))

    scenario = %{
      follow_steps
      | script: List.duplicate(&answer/1, 16),
        config: [max_turns: 12, budget_asks: false],
        drive: &drive/1
    }

    %{record: record, checks: checks, error: nil} = Runner.run(scenario, dir)

    # Every step's file holds what it should, as it did in the live runs.
    assert record["outcome"] == true
    assert Enum.all?(checks, fn {_name, _label, passed} -> passed end), inspect(checks)

    calls = Map.new(record["tools"], &{&1["name"], &1["calls"]})
    assert Map.get(calls, "todo_write", 0) == 0, "the task list took calls: #{inspect(calls)}"

    # The work, then the answer: the run ended by itself, three calls short of the cap.
    assert record["model_calls"] == length(@work) + 1
    assert record["stop_reason"] == "end_turn"
  end

  # The prompt, then the end of the turn, or of the agent when the cap stops it: a budget
  # that stops rather than asks ends the agent without ending its turn (Decision 775).
  defp drive(ctx) do
    sid = ctx.session_id
    :ok = Troupe.send_input(sid, ctx.scenario.prompt)

    receive do
      {:troupe_event, ^sid, %Event{type: type, agent: ["root"], ephemeral?: false}}
      when type in ["turn_ended", "agent_done"] ->
        ctx
    after
      60_000 -> raise "the run never ended"
    end
  end

  # The stand-in's answer, from what the conversation shows it has done so far.
  defp answer(%Request{} = request) do
    made = request.messages |> Enum.flat_map(&tool_calls/1)
    lists = Enum.count(made, &(&1 == "todo_write"))
    worked = length(made) - lists
    done = Enum.count(@step_done_after, &(&1 <= worked))

    cond do
      offered?(request) and worked >= 1 and lists < done + 1 ->
        {:tools, [{"todo_write", %{"items" => items(done)}}]}

      worked < length(@work) ->
        {:tools, [Enum.at(@work, worked)]}

      true ->
        {:text, "Every step of TASK.md is done."}
    end
  end

  defp tool_calls(%Message{role: :assistant} = message),
    do: for(%ToolUse{name: name} <- Message.tool_uses(message), do: name)

  defp tool_calls(_message), do: []

  defp items(done) do
    for n <- 1..@steps do
      status =
        cond do
          n <= done -> "completed"
          n == done + 1 -> "in_progress"
          true -> "pending"
        end

      %{"content" => "Step #{n} of TASK.md", "status" => status}
    end
  end

  # Whether the request offers the tool, which is all the model went by.
  defp offered?(%Request{tools: tools}), do: Enum.any?(tools, &(&1.name == "todo_write"))
end
