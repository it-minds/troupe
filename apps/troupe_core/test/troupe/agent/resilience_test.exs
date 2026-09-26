defmodule Troupe.Agent.ResilienceTest do
  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Server, as: AgentServer
  alias Troupe.LLM.Message
  alias Troupe.Session.{Approvals, Summary}

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
          config_overrides: [max_turns: 3, budget_asks: false],
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

    # The summary `finish` left outlived the turn that gave it, so the first tool turn after
    # a wake finished again at once, with the old summary, before the model saw its results.
    test "a woken agent's tool turn goes back to the model rather than finishing again", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools, [{"finish", %{"summary" => "all done"}}]},
            {:tools, [{"todo_read", %{}}]},
            {:text, "and again"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "do the thing")
      await_state(session.id, [:done], 10_000)

      Troupe.send_input(session.id, "one more thing")
      await_state(session.id, [:idle, :done], 10_000)

      assert Troupe.snapshot(session.id).state == :idle
      assert Fake.call_count(fake) == 3
      assert [%{data: %{"summary" => "all done"}}] = events_of_type(session.id, "agent_done")
    end
  end

  # `child_seq` was not folded, so a restarted agent named its next child `general#1` again,
  # and that child replayed the first one's log instead of taking its task: finished
  # already, it never reported, and the delegation waited for ever.
  describe "a delegation after a restart" do
    test "starts a child of its own on the new task, after the agent restarts", context do
      %{session: session, fake: fake} = start_session(context, routes: two_delegations())

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate the first")
      await_rest(session.id)

      restart_agent(session.id)

      Troupe.send_input(session.id, "delegate the second")
      await_rest(session.id)

      assert_second_child(session.id, fake)
    end

    test "starts a child of its own on the new task, after the session comes back", context do
      %{session: session, fake: fake} = start_session(context, routes: two_delegations())

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate the first")
      await_rest(session.id)

      reopen(context, session.id, fake, [])

      Troupe.send_input(session.id, "delegate the second")
      await_rest(session.id)

      assert_second_child(session.id, fake)
    end

    # A delegation in flight when the agent restarts is taken up again, like any call that
    # had not finished, and a child is started for it afresh on the same task.
    test "that takes up an unfinished one starts that child afresh", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "first task"}}]},
              {:text, "first done"},
              {:tools, [{"delegate", %{"agent" => "general", "task" => "second task"}}]},
              {:text, "second done"}
            ],
            "general" => [
              {:tools, [{"finish", %{"summary" => "first result"}}]},
              {:tools, [{"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 2_000}}]},
              {:tools, [{"finish", %{"summary" => "second result"}}]}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate the first")
      await_rest(session.id)

      Troupe.send_input(session.id, "delegate the second")
      await_started_call(session.id, "slow")
      restart_agent(session.id)
      await_rest(session.id)

      paths = session.id |> events_of_type("delegation_started") |> Enum.map(& &1.data["child_path"])
      assert paths == [["root", "general#1"], ["root", "general#2"], ["root", "general#3"]]

      results =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.agent == ["root"] and &1.data["name"] == "delegate"))
        |> Enum.map(& &1.data["content"])

      assert results == ["first result", "second result"]

      [_first, _second, third] = Fake.requests_for(fake, "general")
      assert [task] = third.messages
      assert Message.text(task) == "second task"

      # The child the restart took down is done in its own log too, with nothing left open
      # (D19): it never reports and its path is never used again.
      old = session.id |> Troupe.events() |> Enum.filter(&(&1.agent == ["root", "general#2"]))
      assert %{type: "agent_done", data: %{"reason" => "interrupted"}} = List.last(old)
      assert open_calls(old) == []
    end
  end

  # A delegation the session stopped in the middle of is closed as interrupted when the
  # session comes back, and nothing restarts its child. The child's own calls stayed open,
  # so an approval it was waiting on stayed open in every reader that follows the log (D18).
  describe "a delegation a restored session closes" do
    test "closes what its subagent had open, so the subagent's approval is not left waiting",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "ask for it"}}]},
              {:text, "never asked"}
            ],
            "general" => [
              {:tools, [{"needs_approval", %{"note" => "child"}}]},
              {:text, "never asked"}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "delegate it")
      request = await_event(sid, :approval_requested)
      child = request.agent
      assert child == ["root", "general#1"]

      reopen(context, sid, fake, auto_approve: false)

      assert eventually(fn -> open_calls(events_of(sid, ["root"])) == [] end)
      assert eventually(fn -> Summary.snapshot(sid)["approvals"] == [] end)
      assert open_calls(events_of(sid, child)) == []
      assert Approvals.pending(sid) == []

      [closed] = sid |> events_of(child) |> Enum.filter(&(&1.type == "tool_call_completed"))
      assert closed.data["call_id"] == request.data["call_id"]
      refute closed.data["ok"]
      assert closed.data["content"] =~ "interrupted"

      assert %{type: "agent_done", data: %{"reason" => "interrupted"}} =
               List.last(events_of(sid, child))

      # Nothing was asked again: the child is not started, and the root takes no turn.
      assert [_asked_once] = events_of_type(sid, "approval_requested")
      assert Troupe.agent_tree(sid) == [["root"]]
    end
  end

  # A failed request's note is part of the conversation the model is sent next, so it has
  # to be in the log that rebuilds the conversation (D19).
  describe "a root whose model request failed" do
    test "still has the failure in its conversation after the session comes back", context do
      %{session: session, fake: fake} =
        start_session(context, steps: [{:error, {:api_error, "the gateway is down"}}])

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "try it")
      await_rest(session.id)

      conversation = Troupe.snapshot(session.id).conversation
      assert Message.text(List.last(conversation)) =~ "The previous model request failed"
      assert Message.text(List.last(conversation)) =~ "the gateway is down"

      reopen(context, session.id, fake, [])

      assert Troupe.snapshot(session.id).conversation == conversation
    end
  end

  # The results of a turn's calls reach the conversation together, once the last is back.
  # A restart in the middle kept only the calls it re-ran or closed, so the results already
  # back went missing — the model is owed a result for every call it made — and a `finish`
  # among them took another model turn instead of ending the agent (D19).
  describe "a turn a restart takes up in the middle" do
    test "keeps the results already back when the session comes back", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"todo_read", %{}},
               {"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 2_000}}
             ]},
            {:text, "never asked"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "read, then count slowly")
      await_completed_call(session.id, "todo_read")
      await_started_call(session.id, "slow")

      reopen(context, session.id, fake, [])
      assert eventually(fn -> open_calls(events_of(session.id, ["root"])) == [] end)

      [results] = events_of_type(session.id, "tool_results")
      assert [%{"content" => [read, count]}] = results.data["results"]
      assert read["error"] in [nil, false]
      assert count["error"] == true
      assert count["content"] =~ "interrupted"

      [_user, _calls, answered] = Troupe.snapshot(session.id).conversation
      assert length(answered.content) == 2
    end

    test "a finish among them ends the agent with its summary, after the agent restarts",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"finish", %{"summary" => "all done"}},
               {"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 1_000}}
             ]},
            {:text, "never asked"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "finish while counting")
      await_completed_call(session.id, "finish")
      await_started_call(session.id, "slow")

      restart_agent(session.id)
      await_state(session.id, [:done], 10_000)

      assert [%{data: %{"reason" => "finished", "summary" => "all done"}}] =
               events_of_type(session.id, "agent_done")

      assert Fake.call_count(fake) == 1
      [results] = events_of_type(session.id, "tool_results")
      assert [%{"content" => [_finished, _counted]}] = results.data["results"]
    end

    test "a subagent's finish among them is what its parent is handed", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", %{"agent" => "general", "task" => "finish while counting"}}]},
              {:text, "root done"}
            ],
            "general" => [
              {:tools,
               [
                 {"finish", %{"summary" => "child result"}},
                 {"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 1_000}}
               ]},
              {:text, "never asked"}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "delegate it")
      await_completed_call(sid, "finish")
      await_started_call(sid, "slow")

      restart_agent(sid, ["root", "general#1"])
      await_rest(sid)

      [result] =
        sid
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.agent == ["root"] and &1.data["name"] == "delegate"))

      assert result.data["content"] == "child result"
      assert [_asked_once] = Fake.requests_for(fake, "general")
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

    # A `finish` in a turn the cancel stopped left its summary behind, and the next turn
    # finished with it as soon as its own tools came back, before the model saw them.
    test "a finish in a cancelled turn does not end the next one", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools,
             [
               {"finish", %{"summary" => "stale"}},
               {"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 2_000}}
             ]},
            {:tools, [{"todo_read", %{}}]},
            {:text, "carried on"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "finish while counting")
      await_started_call(session.id, "slow")
      Troupe.cancel(session.id)
      await_state(session.id, [:idle])

      Troupe.send_input(session.id, "carry on")
      await_state(session.id, [:idle, :done], 10_000)

      assert Troupe.snapshot(session.id).state == :idle
      assert Fake.call_count(fake) == 3
      assert events_of_type(session.id, "agent_done") == []
    end
  end

  # What a cancel killed stays killed. The log is what a restarted agent rebuilds from,
  # so each call the cancel stopped has to be closed there, and the turn has to read as
  # cancelled rather than as one the model still owes.
  describe "a cancelled turn after a restart" do
    # The positive beside the negatives below: without it, a replay that re-dispatched
    # nothing at all would pass them.
    test "without the cancel, a call waiting for approval is put back", context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "one"}}]}, {:text, "done"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "ask me")
      await_event(session.id, :approval_requested)

      reopen(context, session.id, fake, auto_approve: false)

      assert Troupe.snapshot(session.id).outstanding == ["needs_approval"]
    end

    test "a call that was waiting for approval is not asked for again", context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "one"}}]}, {:text, "never asked"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "ask me")
      request = await_event(session.id, :approval_requested)
      Troupe.cancel(session.id)
      await_state(session.id, [:idle])

      conversation = Troupe.snapshot(session.id).conversation
      calls = Fake.call_count(fake)

      reopen(context, session.id, fake, auto_approve: false)

      snapshot = Troupe.snapshot(session.id)
      assert snapshot.state == :idle
      assert snapshot.outstanding == []
      assert Enum.map(snapshot.conversation, & &1.role) == Enum.map(conversation, & &1.role)
      assert Approvals.pending(session.id) == []
      assert [_asked_once] = events_of_type(session.id, "approval_requested")
      assert Fake.call_count(fake) == calls

      [completed] = events_of_type(session.id, "tool_call_completed")
      assert completed.data["call_id"] == request.data["call_id"]
      refute completed.data["ok"]
      assert completed.data["content"] =~ "cancelled"

      # Nothing was in flight when the session stopped, so it did not come back
      # interrupted either.
      [restarted] = events_of_type(session.id, "agent_restarted")
      assert restarted.data["interrupted"] == false
      assert restarted.data["incomplete_calls"] == []
    end

    test "a running tool is not run again", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools, [{"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 400}}]},
            {:text, "never asked"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "count slowly")
      await_started_call(session.id, "slow")
      Troupe.cancel(session.id)
      await_state(session.id, [:idle])
      calls = Fake.call_count(fake)

      restart_agent(session.id)

      snapshot = Troupe.snapshot(session.id)
      assert snapshot.state == :idle
      assert snapshot.outstanding == []
      assert [_started_once] = events_of_type(session.id, "tool_call_started")
      assert Fake.call_count(fake) == calls

      [completed] = events_of_type(session.id, "tool_call_completed")
      refute completed.data["ok"]
      assert completed.data["content"] =~ "cancelled"
    end

    test "a delegation is not made again", context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "ask for it"}}]},
              {:text, "never asked"}
            ],
            "general" => [
              {:tools, [{"needs_approval", %{"note" => "child"}}]},
              {:text, "never asked"}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_event(session.id, :approval_requested)
      Troupe.cancel(session.id)
      await_state(session.id, [:idle])
      calls = Fake.call_count(fake)

      restart_agent(session.id)

      snapshot = Troupe.snapshot(session.id)
      assert snapshot.state == :idle
      assert snapshot.outstanding == []
      assert [_delegated_once] = events_of_type(session.id, "delegation_started")
      assert Fake.call_count(fake) == calls

      [completed] =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.agent == ["root"]))

      assert completed.data["name"] == "delegate"
      refute completed.data["ok"]
    end

    test "a model call is not made again", context do
      %{session: session, fake: fake} =
        start_session(context,
          delay_ms: 2_000,
          steps: [{:text, "too slow"}, {:text, "never asked"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "think slowly")
      await_state(session.id, [:thinking])
      # Asked and not yet answered, so the count below cannot move behind the test's back.
      await_requests(fake, 1)
      Troupe.cancel(session.id)
      await_state(session.id, [:idle])

      restart_agent(session.id)

      assert Troupe.snapshot(session.id).state == :idle
      assert Fake.call_count(fake) == 1
    end
  end

  describe "budgets" do
    test "max_turns stops the agent with :budget_exhausted after exactly that many calls",
         context do
      # A budget that is a contract rather than a question (Decision 660): the plane's
      # terms set this, and `budget_question_test.exs` covers the question.
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [max_turns: 2, budget_asks: false],
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

  defp two_delegations do
    %{
      "root" => [
        {:tools, [{"delegate", %{"agent" => "general", "task" => "first task"}}]},
        {:text, "first done"},
        {:tools, [{"delegate", %{"agent" => "general", "task" => "second task"}}]},
        {:text, "second done"}
      ],
      "general" => [
        {:tools, [{"finish", %{"summary" => "first result"}}]},
        {:tools, [{"finish", %{"summary" => "second result"}}]}
      ]
    }
  end

  defp assert_second_child(session_id, fake) do
    paths = session_id |> events_of_type("delegation_started") |> Enum.map(& &1.data["child_path"])
    assert paths == [["root", "general#1"], ["root", "general#2"]]

    results =
      session_id
      |> events_of_type("tool_call_completed")
      |> Enum.filter(&(&1.agent == ["root"] and &1.data["name"] == "delegate"))
      |> Enum.map(& &1.data["content"])

    assert results == ["first result", "second result"]

    # Seeded with its own task, not replaying the first child's conversation.
    [_first, second] = Fake.requests_for(fake, "general")
    assert [task] = second.messages
    assert Message.text(task) == "second task"
  end

  # The root's turn is over: `turn_ended`, from the log, so a restart's `idle` published
  # from init is not mistaken for it.
  defp await_rest(session_id, timeout \\ 10_000) do
    receive do
      {:troupe_event, ^session_id, %Event{type: "turn_ended", agent: ["root"]}} -> :ok
    after
      timeout -> raise "timed out waiting for the root agent's turn to end"
    end
  end

  # One agent crashing inside a live session: its next start is a warm one, which
  # finishes whatever the log says it had started.
  defp restart_agent(session_id, path \\ ["root"]) do
    agent = Registry.agent_pid(session_id, path)
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
    await_new_agent(session_id, path, agent, 5_000)
  end

  defp events_of(session_id, path),
    do: session_id |> Troupe.events() |> Enum.filter(&(&1.agent == path))

  # Started and never completed.
  defp open_calls(events) do
    events
    |> Enum.reduce(MapSet.new(), fn
      %{type: "tool_call_started", data: %{"call_id" => id}}, open -> MapSet.put(open, id)
      %{type: "tool_call_completed", data: %{"call_id" => id}}, open -> MapSet.delete(open, id)
      _event, open -> open
    end)
    |> MapSet.to_list()
  end

  defp eventually(fun, timeout \\ 5_000),
    do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end

  defp await_completed_call(session_id, name, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id, %Event{type: "tool_call_completed", data: %{"name" => ^name}}} ->
        :ok
    after
      timeout -> raise "timed out waiting for the #{name} call to complete"
    end
  end

  # The whole session going away and coming back, as it does across a daemon restart:
  # the agent's next start is a cold one.
  defp reopen(context, session_id, fake, overrides) do
    :ok = Troupe.stop_session(session_id)
    await_released(session_id, 200)

    {:ok, _session} =
      Troupe.resume(session_id,
        workspace: context.workspace,
        fake: fake,
        config_overrides:
          [provider: "fake", model: "fake-model", state_dir: context.state_dir] ++ overrides
      )

    :ok
  end

  # `stop_session/1` returns before the registry has let go of the session's names, and
  # a resume that wins that race finds a dead pid under them.
  defp await_released(_session_id, 0), do: :ok

  defp await_released(session_id, attempts) do
    if Registry.whereis({:session, session_id}) || Registry.whereis({:log, session_id}) do
      Process.sleep(5)
      await_released(session_id, attempts - 1)
    else
      :ok
    end
  end

  defp await_requests(fake, count, attempts \\ 200) do
    cond do
      Fake.call_count(fake) >= count -> :ok
      attempts == 0 -> flunk("the model was never asked")
      true ->
        Process.sleep(5)
        await_requests(fake, count, attempts - 1)
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
