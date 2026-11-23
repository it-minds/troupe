defmodule Troupe.RecordedCheckpointsTest do
  @moduledoc """
  The terminal's fold against the checkpoints sessions wrote (#1181), in the logs under
  `test/fixtures/checkpoints/` at the repository's root, read through
  `Troupe.Remote.Translate` as a daemon's worker hands them over.

  Two things hold for each checkpoint. Its facts are what this fold says at its `through`
  on the fields both keep: the window's usage, its goal, the root's task list, and what
  waits on a person. And this fold started from the checkpoint, its facts given to it as
  the events they stand for, then the tail, says what the fold from seq 1 says on those
  fields: the history before `through` aside, nothing is lost by starting there.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "checkpoints"]))

  for name <- ~w(manual threshold overflow background_approval) do
    test "#{name}: each checkpoint is the fold at its through, and from it the fold of the whole" do
      log = recorded(unquote(name))
      checkpoints = Enum.filter(log, &(&1["type"] == "checkpoint"))
      assert checkpoints != []
      whole = shared(log)

      for checkpoint <- checkpoints do
        through = checkpoint["data"]["through"]

        assert facts_shared(checkpoint["data"]["facts"]) ==
                 shared(Enum.filter(log, &(&1["seq"] <= through))),
               "the facts at #{through}"

        tail = Enum.filter(log, &(&1["seq"] > through))
        assert shared(seeded(checkpoint) ++ tail) == whole, "from #{checkpoint["seq"]}"
      end
    end
  end

  # The window a subscription from a checkpoint opens (#1183): `Translate.checkpoint/3` in
  # place of the history, then the tail, says what the fold from seq 1 says, and its
  # transcript starts with the summary.
  for name <- ~w(manual threshold overflow background_approval) do
    test "#{name}: a window opened from each checkpoint says what the whole log does" do
      log = recorded(unquote(name))
      whole = shared(log)

      for checkpoint <- Enum.filter(log, &(&1["type"] == "checkpoint")) do
        through = checkpoint["data"]["through"]
        {:ok, seed, memory} = Translate.checkpoint("s-1", checkpoint, Translate.memory())
        assert seed |> Enum.map(&(&1.seq || 0)) |> Enum.max() == through

        {tail, _memory} =
          log
          |> Enum.filter(&(&1["seq"] > through))
          |> Enum.flat_map_reduce(memory, &Translate.durable("s-1", &1, &2))

        [window] = "s-1" |> Model.rebuild("/w", seed ++ tail) |> Model.windows()
        assert local_shared(window) == whole, "from #{checkpoint["seq"]}"

        assert [{:earlier, %{lines: [_ | _]}} | _] = window.agents["root"].transcript
      end
    end
  end

  test "a checkpoint in a shape this client does not read is not started from" do
    [checkpoint | _] = "manual" |> recorded() |> Enum.filter(&(&1["type"] == "checkpoint"))
    unknown = put_in(checkpoint, ["data", "shape"], "session/9")
    assert Translate.checkpoint("s-1", unknown, Translate.memory()) == :unknown
  end

  test "a checkpoint draws nothing in the window" do
    log = recorded("manual")
    without = Enum.reject(log, &(&1["type"] == "checkpoint"))
    assert transcript(log) == transcript(without)
  end

  # What both folds keep, as this one keeps it.
  defp shared(events) do
    [window] = windows(events)
    local_shared(window)
  end

  defp local_shared(window) do
    %{
      usage: window.usage,
      goal: window.goal,
      todos: Enum.map(window.agents["root"].todos, & &1.text),
      pending: window.pending |> Enum.map(& &1.call_id) |> Enum.sort()
    }
  end

  # The same fields, as the checkpoint says them.
  defp facts_shared(facts) do
    usage = facts["usage"]

    %{
      usage: %{
        input: usage["input_tokens"],
        output: usage["output_tokens"],
        cache_read: usage["cache_read"],
        cache_write: usage["cache_write"]
      },
      goal: facts["goal"],
      todos: Enum.map(facts["todos"], & &1["content"]),
      pending:
        (facts["open_approvals"] ++ facts["open_questions"])
        |> Enum.map(& &1["call_id"])
        |> Enum.sort()
    }
  end

  # The checkpoint's facts as events this fold reads, at seqs below its `through`: what a
  # reader starting there begins from.
  defp seeded(checkpoint) do
    facts = checkpoint["data"]["facts"]
    root = ["root"]

    usage = %{
      "message" => %{"role" => "assistant", "content" => []},
      "usage" => facts["usage"]
    }

    open =
      Enum.map(facts["open_approvals"], &{"approval_requested", &1["agent"], &1["data"]}) ++
        Enum.map(facts["open_questions"], &{"question_asked", &1["agent"], &1["data"]})

    goal = if facts["goal"], do: [{"goal_set", root, %{"text" => facts["goal"]}}], else: []

    ([{"agent_started", root, %{"profile" => facts["agent"]}}, {"llm_response", root, usage}] ++
       goal ++ [{"todo_updated", root, %{"items" => facts["todos"]}}] ++ open)
    |> Enum.with_index(1)
    |> Enum.map(fn {{type, agent, data}, seq} ->
      %{
        "seq" => seq,
        "type" => type,
        "agent" => agent,
        "data" => data,
        "actor" => %{"kind" => "system"}
      }
    end)
  end

  defp windows(recorded) do
    "s-1" |> Model.rebuild("/w", translated(recorded)) |> Model.windows()
  end

  defp transcript(recorded) do
    [window] = windows(recorded)
    window.agents["root"].transcript
  end

  defp translated(recorded) do
    {events, _memory} =
      Enum.flat_map_reduce(recorded, Translate.memory(), &Translate.durable("s-1", &1, &2))

    events
  end

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
