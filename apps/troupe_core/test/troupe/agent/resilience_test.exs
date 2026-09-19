defmodule Troupe.Agent.ResilienceTest do
  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Server, as: AgentServer

  describe "tool isolation" do
    test "a tool that raises becomes an error result and the agent survives", context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"boom", %{}}]}, {:text, "recovered"}]
        )

      Troupe.subscribe(session.id)
      agent_before = Registry.agent_pid(session.id, ["root"])

      Troupe.send_input(session.id, "explode")
      await_state(session.id, [:idle])

      [completed] = events_of_type(session.id, "tool_call_completed")
      refute completed.data["ok"]
      assert completed.data["content"] =~ "tool exploded on purpose"

      assert Registry.agent_pid(session.id, ["root"]) == agent_before
      assert Process.alive?(agent_before)
    end

    test "a tool whose process exits becomes an error result", context do
      %{session: session} =
        start_session(context, steps: [{:tools, [{"vanish", %{}}]}, {:text, "recovered"}])

      Troupe.subscribe(session.id)
      agent_before = Registry.agent_pid(session.id, ["root"])

      Troupe.send_input(session.id, "vanish")
      await_state(session.id, [:idle])

      [completed] = events_of_type(session.id, "tool_call_completed")
      refute completed.data["ok"]
      assert Registry.agent_pid(session.id, ["root"]) == agent_before
    end
  end

  describe "crash recovery" do
    test "killing the agent mid-action rebuilds it from the log and re-runs only the unfinished call",
         context do
      marks = "marks.txt"

      # A project profile with the full tool set, so the switch under test does not
      # also change what the agent is allowed to do.
      write_file(context, ".troupe/agents/review.md", """
      ---
      description: review profile for this test
      mode: primary
      budget_share: 1.0
      ---
      You are reviewing.
      """)

      %{session: session} =
        start_session(context,
          steps: [
            # Turn 1: a task list plus a fast call, both of which complete and are logged.
            {:tools,
             [
               {"todo_write",
                %{
                  "items" => [
                    %{"id" => "a", "content" => "first thing", "status" => "completed"},
                    %{"id" => "b", "content" => "second thing", "status" => "in_progress"}
                  ]
                }},
               {"count", %{"path" => marks, "mark" => "first"}}
             ]},
            # Turn 2: a slow call we kill the agent in the middle of.
            {:tools, [{"count", %{"path" => marks, "mark" => "second", "delay_ms" => 400}}]},
            # After the restart the re-run of "second" completes, then this ends it.
            {:text, "done after restart"},
            {:text, "done after restart"}
          ]
        )

      Troupe.subscribe(session.id)

      # Switched while idle, so it is applied and logged before any work starts. A
      # switch sent mid-turn is postponed, and a postponed event lives in the agent's
      # mailbox — it is deliberately not durable across a kill.
      Troupe.switch_profile(session.id, "review")
      await_event(session.id, :profile_switched)

      Troupe.send_input(session.id, "do the thing")

      # Wait for the slow call to be in flight, then kill the agent inside :acting.
      await_started_call(session.id, "second")
      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

      # A restarted agent publishes :idle from init before replaying, so waiting for
      # :idle alone would race the re-run. Wait for the re-dispatch itself.
      await_started_call(session.id, "second")
      await_state(session.id, [:idle, :done], 10_000)

      restarted = Registry.agent_pid(session.id, ["root"])
      assert is_pid(restarted)
      refute restarted == agent

      snapshot = Troupe.snapshot(session.id)

      # Profile, conversation and task list all came back from the log rather than
      # from process memory.
      assert snapshot.profile == "review"
      assert length(snapshot.conversation) >= 4
      assert Enum.map(snapshot.todos, & &1.id) == ["a", "b"]
      assert Enum.map(snapshot.todos, & &1.status) == [:completed, :in_progress]

      marks_content = read_file(context, marks)

      # "first" completed and was logged, so replay must not run it again.
      assert marks_content |> String.split("\n", trim: true) |> Enum.count(&(&1 == "first")) == 1

      # "second" started but never completed, so at-least-once re-runs it.
      assert marks_content =~ "second"
    end
  end

  describe "a finished agent stays finished" do
    test "restarting a :done agent does not start it working again", context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [max_turns: 3],
          steps: [{:tools, [{"todo_read", %{}}]}, {:tools, [{"todo_read", %{}}]}, {:text, "x"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "spend the budget")
      await_state(session.id, [:done], 10_000)

      calls_when_done = Fake.call_count(fake)
      assert calls_when_done == 3

      # Kill it after it finished. Replay must see that it was done: `done_reason`
      # is not in the conversation, so without folding `agent_done` the agent would
      # come back believing it owed the model a turn and spend budget it had none of.
      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

      restarted = await_new_agent(session.id, ["root"], agent, 5_000)
      assert restarted != agent

      snapshot = Troupe.snapshot(session.id)
      assert snapshot.state == :done
      assert snapshot.done_reason == :budget_exhausted
      assert Fake.call_count(fake) == calls_when_done
    end
  end

  describe "a finished agent is woken by input" do
    test "a root agent that called finish takes the next input as a new turn", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools, [{"finish", %{"summary" => "all done"}}]},
            {:text, "and again"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "do the thing")
      await_state(session.id, [:done], 10_000)
      assert [%{data: %{"reason" => "finished"}}] = events_of_type(session.id, "agent_done")
      calls_when_done = Fake.call_count(fake)

      Troupe.send_input(session.id, "one more thing")
      await_state(session.id, [:idle], 10_000)

      # One more model call, on the same conversation, and the agent is idle rather
      # than done: it can be asked again.
      assert Fake.call_count(fake) == calls_when_done + 1
      assert Troupe.snapshot(session.id).state == :idle
      assert Troupe.snapshot(session.id).done_reason == nil

      assert [%{data: %{"from" => "finished", "source" => "user"}}] =
               events_of_type(session.id, "agent_woken")

      assert events_of_type(session.id, "input_after_done") == []
    end

    test "a restarted agent that was woken comes back idle, not done", context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"finish", %{"summary" => "all done"}}]}, {:text, "and again"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "do the thing")
      await_state(session.id, [:done], 10_000)
      Troupe.send_input(session.id, "one more thing")
      await_state(session.id, [:idle], 10_000)

      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

      _restarted = await_new_agent(session.id, ["root"], agent, 5_000)
      assert Troupe.snapshot(session.id).state == :idle
      assert Troupe.snapshot(session.id).done_reason == nil
    end
  end

  describe "cancellation" do
    test "cancel kills a shell command and its grandchild, verified by OS pid", context do
      pidfile = Path.join(context.workspace, "pids.txt")

      %{session: session} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"shell",
                %{
                  "command" => """
                  sleep 60 &
                  echo "grandchild=$!" >> #{pidfile}
                  echo "child=$$" >> #{pidfile}
                  sleep 60
                  """
                }}
             ]},
            {:text, "cancelled"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "run something long")

      pids = await_pids(pidfile)
      assert map_size(pids) == 2
      assert Enum.all?(Map.values(pids), &os_alive?/1)

      Troupe.cancel(session.id)
      await_state(session.id, [:idle])

      assert await_all_dead(Map.values(pids), 1_000),
             "expected #{inspect(pids)} to be gone within 1s of cancelling"
    end

    test "cancel from :idle is a no-op", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      agent = Registry.agent_pid(session.id, ["root"])
      Troupe.cancel(session.id)
      assert AgentServer.snapshot(agent).state == :idle
    end
  end

  describe "budgets" do
    test "max_turns stops the agent with :budget_exhausted after exactly that many calls",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [max_turns: 2],
          steps: [
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "keep going")
      await_state(session.id, [:done], 10_000)

      assert Fake.call_count(fake) == 2

      [done] = events_of_type(session.id, "agent_done")
      assert done.data["reason"] == "budget_exhausted"
      assert done.data["limit"] == "max_turns"

      # A done agent makes no further calls, even when poked.
      Troupe.send_input(session.id, "please continue")
      Process.sleep(50)
      assert Fake.call_count(fake) == 2
    end
  end

  describe "approvals" do
    test "an ask tool blocks until allowed, and a denial is readable", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [
            {:tools, [{"needs_approval", %{"note" => "one"}}]},
            {:tools, [{"needs_approval", %{"note" => "two"}}]},
            {:text, "finished"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "ask me")

      request = await_event(session.id, :approval_requested)
      call_id = request.data["call_id"]
      assert request.data["tool"] == "needs_approval"

      # Nothing completed while the approval was outstanding.
      assert events_of_type(session.id, "tool_call_completed") == []

      Troupe.approve(session.id, call_id, :allow)

      second = await_event(session.id, :approval_requested)
      Troupe.approve(session.id, second.data["call_id"], :deny)

      await_state(session.id, [:idle], 10_000)

      [first, denied] = events_of_type(session.id, "tool_call_completed")
      assert first.data["ok"]
      assert first.data["content"] == "approved: one"
      refute denied.data["ok"]
      assert denied.data["content"] =~ "denied"
    end
  end

  # The registry can still name the dead pid for a moment after a kill, so "it came
  # back" means a pid that is not the one that died.
  defp await_new_agent(session_id, path, previous, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_new_agent(session_id, path, previous, deadline)
  end

  defp do_await_new_agent(session_id, path, previous, deadline) do
    case Registry.agent_pid(session_id, path) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("agent never came back"),
          else: do_await_new_agent(session_id, path, previous, deadline)
    end
  end

  defp await_started_call(session_id, mark, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "tool_call_started", data: %{"args" => %{"mark" => ^mark}}}} ->
        :ok

      _other ->
        await_started_call(session_id, mark, timeout)
    after
      timeout -> raise "timed out waiting for the #{mark} call to start"
    end
  end

  defp await_pids(pidfile, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    pids =
      case File.read(pidfile) do
        {:ok, contents} ->
          contents
          |> String.split("\n", trim: true)
          |> Map.new(fn line ->
            [name, pid] = String.split(line, "=")
            {name, String.to_integer(pid)}
          end)

        {:error, _} ->
          %{}
      end

    cond do
      map_size(pids) == 2 -> pids
      System.monotonic_time(:millisecond) > deadline -> pids
      true -> await_pids(pidfile, deadline)
    end
  end

  defp os_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  defp await_all_dead(pids, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_all_dead(pids, deadline)
  end

  defp do_await_all_dead(pids, deadline) do
    cond do
      Enum.all?(pids, &(not os_alive?(&1))) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> do_await_all_dead(pids, deadline)
    end
  end
end
