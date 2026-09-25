defmodule Troupe.Agent.GoalTest do
  @moduledoc """
  A session's goal: set and cleared as events, folded like the rest of the agent's state,
  and carried into the context of every turn after it is set rather than only the next.

  The model is the scripted fake, so what reached "the context" is read off the requests
  it was sent: the goal rides in the system prompt beside the task list.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Log.Fold

  @goal "the release notes build on Windows"

  describe "setting and clearing" do
    test "a goal set once is in the context of every later turn, not only the next", context do
      %{session: session, fake: fake} =
        start_session(context, steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}])

      Troupe.subscribe(session.id)
      Troupe.set_goal(session.id, @goal, Event.Actor.user("idp|ada", "Ada"))

      set = await_event(session.id, :goal_set)
      assert set.data["text"] == @goal
      assert set.agent == ["root"]
      # Written under whoever set it, which is what makes a shared session's goal legible.
      assert set.actor.subject == "idp|ada"

      for text <- ["first", "second", "third"] do
        Troupe.send_input(session.id, text)
        await_state(session.id, [:idle])
      end

      requests = Fake.requests(fake)
      assert length(requests) == 3
      assert Enum.all?(requests, &(&1.system =~ "<goal>" and &1.system =~ @goal))
      assert Troupe.snapshot(session.id).goal == @goal
    end

    test "clearing it is an event, and takes it out of the next turn's context", context do
      %{session: session, fake: fake} =
        start_session(context, steps: [{:text, "with"}, {:text, "without"}])

      Troupe.subscribe(session.id)
      Troupe.set_goal(session.id, @goal)
      await_event(session.id, :goal_set)
      Troupe.send_input(session.id, "go")
      await_state(session.id, [:idle])

      Troupe.clear_goal(session.id)
      cleared = await_event(session.id, :goal_cleared)
      assert cleared.agent == ["root"]

      Troupe.send_input(session.id, "again")
      await_state(session.id, [:idle])

      [while_set, once_cleared] = Fake.requests(fake)
      assert while_set.system =~ @goal
      refute once_cleared.system =~ @goal
      refute once_cleared.system =~ "<goal>"
      assert Troupe.goal(session.id) == nil
    end

    test "a new goal replaces the old one, and saying the same thing twice writes nothing",
         context do
      %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])

      Troupe.subscribe(session.id)
      Troupe.set_goal(session.id, "first goal")
      await_event(session.id, :goal_set)
      Troupe.set_goal(session.id, "second goal")
      await_event(session.id, :goal_set)
      Troupe.set_goal(session.id, "second goal")
      Troupe.clear_goal(session.id)
      await_event(session.id, :goal_cleared)
      # Nothing to clear, so nothing is written.
      Troupe.clear_goal(session.id)
      Troupe.set_goal(session.id, "third goal")
      await_event(session.id, :goal_set)

      assert session.id |> events_of_type(:goal_set) |> Enum.map(& &1.data["text"]) ==
               ["first goal", "second goal", "third goal"]

      assert length(events_of_type(session.id, :goal_cleared)) == 1

      Troupe.send_input(session.id, "go")
      await_state(session.id, [:idle])
      [request] = Fake.requests(fake)
      assert request.system =~ "third goal"
      refute request.system =~ "second goal"
    end

    test "a goal set while a turn is in flight reaches the model's next request", context do
      %{session: session, fake: fake} =
        start_session(context,
          delay_ms: 150,
          steps: [{:tools, [{"todo_read", %{}}]}, {:text, "done"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "start")

      # Taken at once rather than postponed to the turn boundary: it changes what the
      # next request says, never the one already sent.
      await_event(session.id, :llm_request)
      Troupe.set_goal(session.id, @goal)
      await_event(session.id, :goal_set)
      await_state(session.id, [:idle])

      [first, second] = Fake.requests(fake)
      refute first.system =~ @goal
      assert second.system =~ @goal
    end

    test "only the root agent carries the goal; a subagent is given its task", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "explore", "task" => "look around"}}]},
              {:text, "explored"}
            ],
            "explore" => [{:tools, [{"finish", %{"summary" => "looked"}}]}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.set_goal(session.id, @goal)
      await_event(session.id, :goal_set)
      Troupe.send_input(session.id, "explore")
      await_state(session.id, [:idle], 10_000)

      assert Enum.all?(Fake.requests_for(fake, "root"), &(&1.system =~ @goal))
      refute Enum.any?(Fake.requests_for(fake, "explore"), &(&1.system =~ @goal))
    end
  end

  describe "the goal is folded state" do
    test "a killed agent comes back with its goal, and the next turn still carries it",
         context do
      %{session: session, fake: fake} = start_session(context, steps: [{:text, "after"}])

      Troupe.subscribe(session.id)
      Troupe.set_goal(session.id, @goal)
      await_event(session.id, :goal_set)

      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
      await_event(session.id, :agent_restarted)

      assert Troupe.snapshot(session.id).goal == @goal

      # Not `await_state`: the restarted agent announced `idle` from its own init, and that
      # is still in this mailbox.
      Troupe.send_input(session.id, "carry on")
      await_event(session.id, :llm_response)
      [request] = Fake.requests(fake)
      assert request.system =~ @goal
    end

    test "a stopped session keeps its goal in the log, and a resumed one in its context",
         context do
      %{session: session} = start_session(context, steps: [{:text, "before"}])

      Troupe.subscribe(session.id)
      Troupe.set_goal(session.id, @goal, Event.Actor.user("idp|ada", "Ada"))
      await_event(session.id, :goal_set)
      :ok = stopped(session.id)

      # Reading it while dormant, without bringing the tree back, is the daemon test's:
      # it needs the state directory a daemon finds on its own, and this one is per test.
      fake = start_supervised!({Fake, steps: [{:text, "after"}]}, id: :resumed_fake)

      {:ok, _resumed} =
        Troupe.resume(session.id,
          workspace: context.workspace,
          fake: fake,
          config_overrides: [provider: "fake", auto_approve: true, state_dir: context.state_dir]
        )

      on_exit(fn -> Troupe.stop_session(session.id) end)
      Troupe.subscribe(session.id)
      assert Troupe.snapshot(session.id).goal == @goal
      assert %{text: @goal, set_by: "idp|ada", set_at: set_at} = Troupe.goal(session.id)
      assert is_binary(set_at)

      Troupe.send_input(session.id, "and now")
      await_event(session.id, :llm_response)
      [request] = Fake.requests(fake)
      assert request.system =~ @goal
    end

    test "the fold witnesses the goal, and a log without one folds as it always did" do
      base = [event(1, :user_input, %{"source" => "user", "text" => "hello"})]
      set = base ++ [event(2, :goal_set, %{"text" => @goal})]
      cleared = set ++ [event(3, :goal_cleared, %{})]

      assert Fold.state(set)["agents"]["root"]["goal"] == @goal
      assert Fold.hash(set) != Fold.hash(base)
      refute Map.has_key?(Fold.state(base)["agents"]["root"], "goal")
      refute Map.has_key?(Fold.state(cleared)["agents"]["root"], "goal")
    end
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

  defp event(seq, type, data) do
    %Event{
      seq: seq,
      type: to_string(type),
      agent: ["root"],
      data: data,
      actor: Event.Actor.system(),
      ts: "2026-01-01T00:00:00.000000Z"
    }
  end
end
