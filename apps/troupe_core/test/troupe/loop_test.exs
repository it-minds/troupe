defmodule Troupe.LoopTest do
  @moduledoc """
  The loop's state machine without a process: every transition `Troupe.Loop` decides, as
  the events it would write, and the fold that replays them. Each test writes what a
  decision returns into a list of sealed events and folds it, which is exactly what the
  loop process does and what a replay does later — so "the live loop and the replayed one
  agree" is the property every assertion here rests on. The process around it is
  `Troupe.Session.LoopTest`'s.
  """

  use ExUnit.Case, async: true

  alias Troupe.Loop
  alias Troupe.Protocol.Event

  @goal "the release notes build on Windows"

  # A log in the making: the events so far, and the loop they fold to.
  defp started(opts \\ []) do
    events =
      Loop.start("loop-1",
        max_iterations: Keyword.get(opts, :max_iterations, 3),
        max_failures: Keyword.get(opts, :max_failures, 2),
        goal: @goal,
        command_id: "c-1"
      )

    write([], events, Event.Actor.user("idp|ada", "Ada"))
  end

  defp write(log, events, actor \\ Event.Actor.system()) do
    seq = length(log)

    sealed =
      events
      |> Enum.with_index(seq + 1)
      |> Enum.map(fn {{type, data}, n} ->
        %Event{
          seq: n,
          type: Atom.to_string(type),
          agent: ["root"],
          data: data,
          actor: actor,
          ts: "2026-09-23T12:00:00.000000Z"
        }
      end)

    log ++ sealed
  end

  # One decision, written and folded: what the process does between two messages.
  defp step(log, decide) do
    log = write(log, decide.(Loop.fold(log)))
    {log, Loop.fold(log)}
  end

  defp types(log), do: Enum.map(log, & &1.type)

  describe "starting" do
    test "a loop starts running at iteration 0, with its cap, its goal and who started it" do
      loop = Loop.fold(started())

      assert %Loop{id: "loop-1", status: :running, iteration: 0, max_iterations: 3, in_flight: nil} = loop
      assert loop.goal == @goal
      assert loop.started_by == "idp|ada"
      assert Loop.running?(loop)
    end

    test "the first step is iteration 1, whose input carries a command id of its own" do
      {log, loop} = step(started(), &Loop.next(&1, nil))

      assert List.last(log).data == %{"loop_id" => "loop-1", "iteration" => 1, "command_id" => "loop-1.1"}
      assert %Loop{iteration: 1, in_flight: "loop-1.1"} = loop
    end

    test "ids count the loops the log already has" do
      assert Loop.next_id([]) == "loop-1"
      assert Loop.next_id(started()) == "loop-2"
    end
  end

  describe "between iterations" do
    test "an iteration that ends without goal_complete is followed by the next" do
      {log, _} = step(started(), &Loop.next(&1, nil))
      {log, loop} = step(log, &Loop.finish(&1, :continue))

      assert %Loop{iteration: 1, in_flight: nil, status: :running} = loop
      assert List.last(log).data["outcome"] == "continue"

      {_log, loop} = step(log, &Loop.next(&1, nil))
      assert %Loop{iteration: 2, in_flight: "loop-1.2"} = loop
    end

    test "goal_complete ends the loop with the evidence the call gave" do
      {log, _} = step(started(), &Loop.next(&1, nil))
      {log, loop} = step(log, &Loop.finish(&1, :complete, summary: "mix test: 0 failures"))

      assert Enum.take(types(log), -2) == ["loop_iteration_finished", "loop_stopped"]
      assert %Loop{status: :stopped, reason: "goal_complete", summary: "mix test: 0 failures"} = loop
      refute Loop.running?(loop)
      # Nothing follows a stopped loop.
      assert Loop.next(loop, nil) == []
    end

    test "the cap stops the loop after its last iteration, not before it" do
      log = started(max_iterations: 2)
      {log, _} = step(log, &Loop.next(&1, nil))
      {log, _} = step(log, &Loop.finish(&1, :continue))
      {log, loop} = step(log, &Loop.next(&1, nil))
      assert loop.iteration == 2

      {log, _} = step(log, &Loop.finish(&1, :continue))
      {log, loop} = step(log, &Loop.next(&1, nil))

      assert %Loop{status: :stopped, reason: "max_iterations"} = loop
      assert List.last(log).data["iterations"] == 2
    end

    test "failures in a row stop the loop at the threshold, and a success in between resets the count" do
      log = started(max_iterations: 10, max_failures: 2)

      {log, _} = step(log, &Loop.next(&1, nil))
      {log, loop} = step(log, &Loop.finish(&1, :failed, detail: "the model request failed"))
      assert %Loop{failures: 1, status: :running} = loop

      {log, _} = step(log, &Loop.next(&1, nil))
      {log, loop} = step(log, &Loop.finish(&1, :continue))
      assert loop.failures == 0

      {log, _} = step(log, &Loop.next(&1, nil))
      {log, _} = step(log, &Loop.finish(&1, :failed, detail: "one"))
      {log, _} = step(log, &Loop.next(&1, nil))
      {log, loop} = step(log, &Loop.finish(&1, :failed, detail: "two"))

      assert %Loop{status: :stopped, reason: "failures", detail: "two", iteration: 4} = loop
      assert Enum.count(log, &(&1.data["outcome"] == "failed")) == 3
    end

    test "a root that will take no more input stops the loop instead of starting an iteration" do
      log = started()

      assert [{:loop_stopped, %{"reason" => "budget"}}] = Loop.next(Loop.fold(log), "budget_exhausted")

      assert [{:loop_stopped, %{"reason" => "agent_done", "detail" => "refused"}}] =
               Loop.next(Loop.fold(log), "refused")

      # A root that finished is woken by the next input, so the loop goes on.
      assert [{:loop_iteration_started, _}] = Loop.next(Loop.fold(log), "finished")
    end
  end

  describe "stopping" do
    test "stopping mid-iteration closes the iteration as stopped, then the loop" do
      {log, _} = step(started(), &Loop.next(&1, nil))
      {log, loop} = step(log, &Loop.stop(&1, :requested, command_id: "c-9"))

      assert Enum.take(types(log), -2) == ["loop_iteration_finished", "loop_stopped"]
      assert Enum.at(log, -2).data["outcome"] == "stopped"
      assert List.last(log).data == %{"loop_id" => "loop-1", "reason" => "requested", "iterations" => 1, "command_id" => "c-9"}
      assert %Loop{status: :stopped, reason: "requested", in_flight: nil} = loop
    end

    test "stopping between iterations writes only the loop's end" do
      {log, _} = step(started(), &Loop.next(&1, nil))
      {log, _} = step(log, &Loop.finish(&1, :continue))
      before = length(log)
      {log, loop} = step(log, &Loop.stop(&1, :interrupted))

      assert log |> Enum.drop(before) |> types() == ["loop_stopped"]
      assert loop.reason == "interrupted"
    end

    test "every reason a loop stops for is one the log can spell" do
      reasons =
        ~w(goal_complete max_iterations failures budget requested cancelled goal_cleared interrupted agent_done)a

      spelled =
        for reason <- reasons do
          [{:loop_stopped, data}] = Loop.stop(Loop.fold(started()), reason)
          data["reason"]
        end

      assert spelled == Loop.reasons()
    end
  end

  describe "replay" do
    test "the latest loop wins, and events naming another loop or another agent change nothing" do
      {log, _} = step(started(), &Loop.stop(&1, :requested))

      second =
        Loop.start("loop-2", max_iterations: 5, max_failures: 3, goal: "another goal")

      log = write(log, second)
      stray = %{List.last(log) | seq: 99, type: "loop_stopped", data: %{"loop_id" => "loop-1", "reason" => "budget"}}
      elsewhere = %{stray | agent: ["root", "explore#1"], data: %{"loop_id" => "loop-2", "reason" => "budget"}}

      loop = Loop.fold(log ++ [stray, elsewhere])

      assert %Loop{id: "loop-2", status: :running, max_iterations: 5, goal: "another goal"} = loop
    end

    test "a log with no loop folds to nothing" do
      assert Loop.fold([]) == nil

      assert Loop.fold([%Event{seq: 1, type: "user_input", agent: ["root"], data: %{"text" => "hi"}}]) ==
               nil
    end

    test "a running loop in a session that is not running reads as interrupted" do
      {log, loop} = step(started(), &Loop.next(&1, nil))
      assert log != []

      assert %{"state" => "running", "reason" => nil, "iteration" => 1} = Loop.to_json(loop, true)
      assert %{"state" => "stopped", "reason" => "interrupted"} = Loop.to_json(loop, false)

      {_log, stopped} = step(log, &Loop.stop(&1, :requested))
      assert %{"state" => "stopped", "reason" => "requested"} = Loop.to_json(stopped, false)
    end
  end
end
