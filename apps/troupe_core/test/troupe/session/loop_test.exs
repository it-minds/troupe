defmodule Troupe.Session.LoopTest do
  @moduledoc """
  `/loop` in a running session (issue #59, Decision 681): iterations are the root agent's
  own turns, each one's verdict is a `goal_complete` call or its absence, and the loop
  stops on the goal, the cap, failures in a row, the budget question, a cancel, a cleared
  goal or `/loop stop` — each written as `loop_*` events a replay folds back to the same
  loop. Then the restarts: the loop process alone, the agent alone, and the whole tree.

  The model is the scripted fake, so "the agent decided the goal was met" is a step that
  calls `goal_complete`, and what reached the model is read off the requests it was sent.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Message
  alias Troupe.Loop
  alias Troupe.Session.Loop, as: LoopProcess

  @goal "the release notes build on Windows"
  @ada Event.Actor.user("idp|ada", "Ada")

  defp start_with_goal(context, opts) do
    %{session: session} = started = start_session(context, opts)
    Troupe.subscribe(session.id)
    Troupe.set_goal(session.id, @goal)
    await_event(session.id, :goal_set)
    Map.put(started, :sid, session.id)
  end

  defp loop_events(sid), do: sid |> Troupe.events() |> Enum.filter(&String.starts_with?(&1.type, "loop_"))
  defp outcomes(sid), do: sid |> events_of_type(:loop_iteration_finished) |> Enum.map(& &1.data["outcome"])
  defp tool_names(request), do: Enum.map(request.tools, & &1.name)

  defp flush do
    receive do
      {:troupe_event, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  test "a session with no goal has nothing to loop towards, and nothing is written", context do
    %{session: session} = start_session(context, steps: [])

    assert Troupe.start_loop(session.id) == {:error, :no_goal}
    assert loop_events(session.id) == []
    assert Troupe.loop(session.id) == nil
  end

  describe "iterations" do
    test "each iteration is a root turn, and a goal_complete call ends the loop with its evidence",
         context do
      %{sid: sid, fake: fake} =
        start_with_goal(context,
          steps: [
            {:text, "made some progress"},
            {:tools, [{"goal_complete", %{"summary" => "the notes build and the test passes"}}]},
            {:text, "the goal is met"}
          ]
        )

      assert {:ok, %Loop{id: "loop-1", max_iterations: 5}} =
               Troupe.start_loop(sid, @ada, max_iterations: 5, command_id: "c-loop")

      stopped = await_event(sid, :loop_stopped, 10_000)
      assert stopped.data["reason"] == "goal_complete"
      assert stopped.data["summary"] == "the notes build and the test passes"
      assert stopped.data["iterations"] == 2

      assert Enum.map(loop_events(sid), & &1.type) == ~w(
               loop_started loop_iteration_started loop_iteration_finished
               loop_iteration_started loop_iteration_finished loop_stopped
             )

      assert outcomes(sid) == ["continue", "complete"]

      [started | _] = loop_events(sid)
      assert started.actor.subject == "idp|ada"
      assert started.data["goal"] == @goal
      assert started.data["command_id"] == "c-loop"

      # The loop's inputs are the root's own turns, told apart from a person's.
      assert sid |> events_of_type(:user_input) |> Enum.map(& &1.data["source"]) == ["loop", "loop"]

      assert sid |> events_of_type(:input_accepted) |> Enum.map(&{&1.data["command_id"], &1.data["author"]}) ==
               [{"loop-1.1", "loop"}, {"loop-1.2", "loop"}]

      # `goal_complete` is offered on the loop's turns and on no others.
      requests = Fake.requests(fake)
      assert length(requests) == 3
      assert Enum.all?(requests, &("goal_complete" in tool_names(&1)))
      assert Enum.all?(requests, &(&1.system =~ @goal))
      assert hd(requests).messages |> List.last() |> Message.text() =~ "Loop iteration 1 of 5"

      flush()
      Troupe.send_input(sid, "thanks")
      await_state(sid, [:idle])
      assert [_, _, _, after_loop] = Fake.requests(fake)
      refute "goal_complete" in tool_names(after_loop)
    end

    test "the live loop and the one folded from its log are the same loop", context do
      %{sid: sid} = start_with_goal(context, steps: [{:text, "one"}, {:text, "two"}])

      {:ok, _loop} = Troupe.start_loop(sid, @ada, max_iterations: 2)
      await_event(sid, :loop_stopped, 10_000)

      live = LoopProcess.current(sid)
      replayed = sid |> Troupe.events() |> Loop.fold()

      assert Map.drop(live, [:started_at]) == Map.drop(replayed, [:started_at])
      assert %Loop{status: :stopped, reason: "max_iterations", iteration: 2} = replayed

      assert %{"state" => "stopped", "reason" => "max_iterations", "iteration" => 2, "max_iterations" => 2} =
               Troupe.loop(sid)
    end

    test "the cap comes from config when the loop is not given one", context do
      %{sid: sid, fake: fake} =
        start_with_goal(context, steps: [{:text, "one"}], config_overrides: [loop_max_iterations: 1])

      assert {:ok, %Loop{max_iterations: 1}} = Troupe.start_loop(sid)

      assert %{data: %{"reason" => "max_iterations", "iterations" => 1}} =
               await_event(sid, :loop_stopped, 10_000)

      assert Fake.call_count(fake) == 1
    end

    test "only one loop runs at a time", context do
      %{sid: sid} = start_with_goal(context, delay_ms: 200, steps: [{:text, "slow"}])

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 1)
      assert Troupe.start_loop(sid) == {:error, {:already_running, "loop-1"}}

      await_event(sid, :loop_stopped, 10_000)
      assert {:ok, %Loop{id: "loop-2"}} = Troupe.start_loop(sid, nil, max_iterations: 1)
      await_event(sid, :loop_stopped, 10_000)
    end

    test "failed iterations in a row stop the loop at the configured threshold", context do
      %{sid: sid, fake: fake} =
        start_with_goal(context,
          steps: [{:error, "overloaded"}, {:error, "overloaded"}, {:text, "never reached"}],
          config_overrides: [loop_max_failures: 2]
        )

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 10)

      stopped = await_event(sid, :loop_stopped, 10_000)
      assert stopped.data["reason"] == "failures"
      assert stopped.data["detail"] =~ "the model request failed"
      assert outcomes(sid) == ["failed", "failed"]
      assert Fake.call_count(fake) == 2
    end
  end

  describe "stopping" do
    test "/loop stop mid-iteration cancels the loop's turn, and nothing further runs", context do
      %{sid: sid, fake: fake} =
        start_with_goal(context, delay_ms: 200, steps: [{:tools, [{"todo_read", %{}}]}, {:text, "never"}])

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 5)
      await_event(sid, :llm_request)

      assert :ok = Troupe.stop_loop(sid, Event.Actor.user("idp|bob", "Bob"), command_id: "c-stop")

      stopped = await_event(sid, :loop_stopped)
      assert stopped.data["reason"] == "requested"
      assert stopped.data["command_id"] == "c-stop"
      assert stopped.actor.subject == "idp|bob"
      await_event(sid, :cancelled)
      await_state(sid, [:idle])

      assert outcomes(sid) == ["stopped"]
      assert length(events_of_type(sid, :loop_iteration_started)) == 1
      # The one request of the cancelled turn, at most: nothing after the stop asked again.
      assert Fake.call_count(fake) <= 1

      # Nothing is running, so a second stop writes nothing.
      assert :ok = Troupe.stop_loop(sid)
      assert length(events_of_type(sid, :loop_stopped)) == 1
    end

    test "stopping leaves a person's own turn alone, and drops the iteration queued behind it",
         context do
      %{sid: sid, fake: fake} = start_with_goal(context, delay_ms: 300, steps: [{:text, "my answer"}])

      Troupe.send_input(sid, "a question of my own")
      await_event(sid, :llm_request)

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 3)
      await_event(sid, :loop_iteration_started)
      :ok = Troupe.stop_loop(sid)
      await_event(sid, :loop_stopped)

      await_state(sid, [:idle])
      # A call is taken after the queued input the turn's end released, so by now the
      # agent has had the stale iteration and done whatever it was going to do with it.
      assert %{state: :idle} = Troupe.snapshot(sid)

      assert events_of_type(sid, :cancelled) == []
      assert sid |> events_of_type(:user_input) |> Enum.map(& &1.data["source"]) == ["user"]
      assert Fake.call_count(fake) == 1
    end

    test "the budget question stops the loop and stays with the person", context do
      %{sid: sid} =
        start_with_goal(context,
          steps: [{:tools, [{"todo_read", %{}}]}, {:text, "more"}],
          config_overrides: [max_turns: 1]
        )

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 5)

      stopped = await_event(sid, :loop_stopped, 10_000)
      assert stopped.data["reason"] == "budget"
      assert stopped.data["detail"] =~ "turns"
      assert outcomes(sid) == ["stopped"]
      assert [_asked] = events_of_type(sid, :budget_ask_started)
    end

    test "a person cancelling the loop's turn stops the loop", context do
      %{sid: sid} = start_with_goal(context, delay_ms: 200, steps: [{:tools, [{"todo_read", %{}}]}])

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 5)
      await_event(sid, :llm_request)
      Troupe.cancel(sid)

      assert %{data: %{"reason" => "cancelled"}} = await_event(sid, :loop_stopped)
      assert outcomes(sid) == ["stopped"]
    end

    test "clearing the goal stops the loop and lets the turn in flight finish", context do
      %{sid: sid} =
        start_with_goal(context, delay_ms: 150, steps: [{:tools, [{"todo_read", %{}}]}, {:text, "wrapped up"}])

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 5)
      await_event(sid, :llm_request)
      Troupe.clear_goal(sid)

      assert %{data: %{"reason" => "goal_cleared"}} = await_event(sid, :loop_stopped)
      await_state(sid, [:idle])

      assert events_of_type(sid, :cancelled) == []
      assert Enum.any?(events_of_type(sid, :llm_response), &(inspect(&1.data["message"]) =~ "wrapped up"))
    end
  end

  describe "restarts" do
    test "a loop process that crashes carries on from the log", context do
      %{sid: sid} = start_with_goal(context, delay_ms: 150, steps: [], default: {:text, "a step"})

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 3)
      await_event(sid, :llm_request)

      pid = Registry.whereis({:loop, sid})
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Nobody saw the iteration in flight end, so it is closed as a failure, and the loop
      # goes on to its cap.
      finished = await_event(sid, :loop_iteration_finished, 10_000)
      assert finished.data["outcome"] == "failed"
      assert finished.data["detail"] =~ "the loop restarted"

      assert %{data: %{"reason" => "max_iterations", "iterations" => 3}} = await_event(sid, :loop_stopped, 10_000)
      assert outcomes(sid) == ["failed", "continue", "continue"]
    end

    test "an agent that crashes mid-iteration fails that iteration and the loop goes on", context do
      %{sid: sid} = start_with_goal(context, delay_ms: 150, steps: [], default: {:text, "a step"})

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 2)
      await_event(sid, :llm_request)

      agent = Registry.agent_pid(sid, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}

      finished = await_event(sid, :loop_iteration_finished, 10_000)
      assert finished.data["outcome"] == "failed"
      assert finished.data["detail"] =~ "the agent restarted"

      assert %{data: %{"reason" => "max_iterations"}} = await_event(sid, :loop_stopped, 10_000)
      assert outcomes(sid) == ["failed", "continue"]
      # The restarted agent was told which loop it serves: the second iteration ran.
      assert "loop-1.2" in (sid |> events_of_type(:input_accepted) |> Enum.map(& &1.data["command_id"]))
    end

    test "a session that comes back from a stop marks its loop interrupted and runs nothing", context do
      %{sid: sid} = start_with_goal(context, delay_ms: 300, steps: [{:text, "slow"}])

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 3)
      await_event(sid, :llm_request)
      :ok = stopped(sid)

      fake = start_supervised!({Fake, steps: [], default: {:text, "should not run"}}, id: :resumed_fake)
      resume(context, sid, fake, [])

      # A call is answered after the process has recovered.
      assert %Loop{status: :stopped, reason: "interrupted"} = LoopProcess.current(sid)
      assert List.last(outcomes(sid)) == "stopped"
      assert [%{data: %{"reason" => "interrupted", "iterations" => 1}}] = events_of_type(sid, :loop_stopped)
      assert Fake.call_count(fake) == 0
    end

    test "with resume_on_restart the loop carries on after the session comes back", context do
      %{sid: sid} = start_with_goal(context, delay_ms: 300, steps: [{:text, "slow"}])

      {:ok, _} = Troupe.start_loop(sid, nil, max_iterations: 2)
      await_event(sid, :llm_request)
      :ok = stopped(sid)
      flush()

      fake = start_supervised!({Fake, steps: [], default: {:text, "carried on"}}, id: :resumed_fake)
      resume(context, sid, fake, resume_on_restart: true)

      assert %{data: %{"reason" => "max_iterations", "iterations" => 2}} = await_event(sid, :loop_stopped, 10_000)
      assert outcomes(sid) == ["failed", "continue"]
    end
  end

  defp resume(context, sid, fake, overrides) do
    {:ok, _resumed} =
      Troupe.resume(sid,
        workspace: context.workspace,
        fake: fake,
        config_overrides:
          [provider: "fake", auto_approve: true, model: "fake-model", state_dir: context.state_dir] ++
            overrides
      )

    on_exit(fn -> Troupe.stop_session(sid) end)
  end

  # `stop_session/1` returns before `Registry` has noticed the exit (see ReopeningTest).
  defp stopped(session_id) do
    :ok = Troupe.stop_session(session_id)
    wait_for_release(session_id, 200)
  end

  defp wait_for_release(_session_id, 0), do: :ok

  defp wait_for_release(session_id, attempts) do
    if Registry.whereis({:session, session_id}) || Registry.whereis({:log, session_id}) do
      Process.sleep(5)
      wait_for_release(session_id, attempts - 1)
    else
      :ok
    end
  end
end
