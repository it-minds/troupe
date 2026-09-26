defmodule Troupe.Agent.DelegationTest do
  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Agent.Node, as: AgentNode
  alias Troupe.LLM.ToolResult

  # How many times `kill_until_gone/3` may kill the agent before giving up, and so also
  # how many answers the doomed child's script has to have.
  @kill_attempts 12

  describe "parallel delegation" do
    test "the root delegates to four children and gets four results", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               Enum.map(1..4, fn n ->
                 {"delegate", %{"agent" => "general", "task" => "task #{n}"}}
               end)},
              {:text, "all four came back"}
            ],
            # Four children run concurrently, so their answers come from one route
            # rather than from the root's list, where the interleaving would decide
            # who got which step.
            "general" => List.duplicate({:tools, [{"finish", %{"summary" => "child result"}}]}, 4)
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "do four things")
      await_root_idle(session.id)

      started = events_of_type(session.id, "delegation_started")
      assert length(started) == 4

      completed =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.data["name"] == "delegate"))

      assert length(completed) == 4
      assert Enum.all?(completed, & &1.data["ok"])
      assert Enum.all?(completed, &(&1.data["content"] == "child result"))
    end

    test "one child failing past its restart intensity fails only its own delegation",
         context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [
                 {"delegate", %{"agent" => "general", "task" => "one"}},
                 {"delegate", %{"agent" => "general", "task" => "two"}},
                 {"delegate", %{"agent" => "general", "task" => "three"}},
                 {"delegate", %{"agent" => "doomed", "task" => "four"}}
               ]},
              {:text, "three of four"}
            ],
            "general" => List.duplicate({:tools, [{"finish", %{"summary" => "ok"}}]}, 3),
            # The doomed child never answers: the test kills it until its Node gives up.
            # A restarted agent asks again, so there is a step here for every kill: a
            # request whose answer the kill threw away has still consumed its step, and
            # one step alone would leave the next request to the fake's default — a
            # plain reply, which is a child that *finished*, not one that failed.
            "doomed" =>
              List.duplicate({:tools, [{"shell", %{"command" => "sleep 30"}}]}, @kill_attempts)
          },
          definitions: definitions_with_doomed()
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "do four things, one will fail")

      doomed_path = await_delegation_path(session.id, "doomed")
      kill_until_gone(session.id, doomed_path)

      await_root_idle(session.id, 15_000)

      results =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.data["name"] == "delegate"))

      assert length(results) == 4
      assert Enum.count(results, & &1.data["ok"]) == 3

      failure = Enum.find(results, &(not &1.data["ok"]))
      assert failure.data["content"] =~ "delegated agent failed"
    end
  end

  describe "a subagent that runs out of budget" do
    test "reports what it found rather than throwing the work away", context do
      %{session: session} =
        start_session(context,
          config_overrides: [max_turns: 20],
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            # The child says something useful, then keeps calling tools until its
            # slice of the budget runs out without ever calling `finish`.
            "general" =>
              [
                {:text_and_tools, "I found the retry logic in lib/retry.ex.",
                 [{"todo_read", %{}}]}
              ] ++
                List.duplicate({:tools, [{"todo_read", %{}}]}, 20)
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate something open-ended")
      await_root_idle(session.id, 20_000)

      result =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.find(&(&1.data["name"] == "delegate"))

      # A successful result, because partial findings are usable; the content says
      # plainly that it was cut short.
      assert result.data["ok"]
      assert result.data["content"] =~ "cut short"
      assert result.data["content"] =~ "ran out of budget"
      assert result.data["content"] =~ "I found the retry logic in lib/retry.ex."
    end

    test "says so plainly when it produced nothing at all", context do
      %{session: session} =
        start_session(context,
          config_overrides: [max_turns: 20],
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            "general" => List.duplicate({:tools, [{"todo_read", %{}}]}, 20)
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate something open-ended")
      await_root_idle(session.id, 20_000)

      result =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.find(&(&1.data["name"] == "delegate"))

      assert result.data["content"] =~ "before reporting anything"
    end

    test "does not hand over whitespace as its findings", context do
      %{session: session} =
        start_session(context,
          config_overrides: [max_turns: 20],
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            # Some models open a turn with a bare "\n\n" before its tool calls and leave
            # the text of every later one empty: nothing the parent could act on.
            "general" =>
              [{:text_and_tools, "\n\n", [{"todo_read", %{}}]}] ++
                List.duplicate({:text_and_tools, "", [{"todo_read", %{}}]}, 20)
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate something open-ended")
      await_root_idle(session.id, 20_000)

      result =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.find(&(&1.data["name"] == "delegate"))

      assert result.data["content"] =~ "before reporting anything"
      refute result.data["content"] =~ "cut short"
    end
  end

  describe "a subagent whose model request fails" do
    # A root rests after a failed request and waits for the person to say try again. A
    # subagent has nobody to say it: resting left its parent's `delegate` open for ever.
    test "hands its parent what it found, labelled cut short", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            "general" => [
              {:text_and_tools, "I found the retry logic in lib/retry.ex.", [{"todo_read", %{}}]},
              {:error, {:api_error, "the gateway is down"}}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_root_idle(session.id)

      result = session.id |> events_of_type("tool_call_completed") |> Enum.find(&(&1.data["name"] == "delegate"))
      assert result.data["ok"]
      assert result.data["content"] =~ "cut short"
      assert result.data["content"] =~ "model request failed"
      assert result.data["content"] =~ "the gateway is down"
      assert result.data["content"] =~ "I found the retry logic in lib/retry.ex."

      [child] = Enum.filter(events_of_type(session.id, "agent_done"), &(&1.agent != ["root"]))
      assert child.data["reason"] == "llm_error"
      assert Troupe.snapshot(session.id).state == :idle
    end

    test "says so plainly when it failed before reporting anything", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            "general" => [{:error, {:api_error, "the gateway is down"}}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_root_idle(session.id)

      result = session.id |> events_of_type("tool_call_completed") |> Enum.find(&(&1.data["name"] == "delegate"))
      assert result.data["content"] =~ "before it reported anything"
      assert result.data["content"] =~ "the gateway is down"
      refute result.data["content"] =~ "cut short"

      [child] = Enum.filter(events_of_type(session.id, "agent_done"), &(&1.agent != ["root"]))
      assert child.data["reason"] == "llm_error"
    end
  end

  describe "a delegate's turns" do
    # Issue #118: a share of the root's remaining turns gave an `explore` asked to read an
    # app 13 or 14 turns, and six of seven ran out reading before they reported.
    test "are its own, so an explore delegated late in a root's turn still finishes", context do
      write_file(context, "mix.exs", "defmodule App.MixProject do\nend\n")

      %{session: session} =
        start_session(context,
          routes: %{
            "root" =>
              List.duplicate({:tools, [{"todo_read", %{}}]}, 6) ++
                [
                  {:tools, [{"delegate", %{"agent" => "explore", "task" => "summarise the app"}}]},
                  {:text, "root done"}
                ],
            "explore" =>
              List.duplicate({:tools, [{"read_file", %{"path" => "mix.exs"}}]}, 20) ++
                [{:tools, [{"finish", %{"summary" => "an app with a mix.exs"}}]}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "look at the app")
      await_root_idle(session.id, 20_000)

      result =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.find(&(&1.data["name"] == "delegate"))

      assert result.data["ok"]
      assert result.data["content"] == "an app with a mix.exs"

      [explore] = Enum.filter(events_of_type(session.id, "agent_done"), &(&1.agent != ["root"]))
      assert explore.data["reason"] == "finished"
    end
  end

  describe "a delegate's final reply" do
    test "is handed over trimmed", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            "general" => [{:text, "\n\nThe retry logic is in lib/retry.ex.\n"}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_root_idle(session.id)

      result = session.id |> events_of_type("tool_call_completed") |> Enum.find(&(&1.data["name"] == "delegate"))
      assert result.data["content"] == "The retry logic is in lib/retry.ex."
    end

    test "of whitespace alone is not a summary: it is nudged once, then ends empty", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
              {:text, "root done"}
            ],
            "general" => [{:text, "\n\n"}, {:text, "  \n"}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_root_idle(session.id)

      result = session.id |> events_of_type("tool_call_completed") |> Enum.find(&(&1.data["name"] == "delegate"))
      assert result.data["content"] =~ "no text and no tool call"
      assert length(Fake.requests_for(fake, "general")) == 2

      [child] = Enum.filter(events_of_type(session.id, "agent_done"), &(&1.agent != ["root"]))
      assert child.data["reason"] == "empty_reply"
    end
  end

  describe "no orphans" do
    test "killing a parent Node leaves nothing alive under it", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "spawn grandchildren"}}]},
              {:text, "done"}
            ],
            # The first child delegates twice more, so there is a real subtree to kill;
            # the grandchildren then sit in a long shell call.
            "general" => [
              {:tools,
               [
                 {"delegate", %{"agent" => "general", "task" => "deep one"}},
                 {"delegate", %{"agent" => "general", "task" => "deep two"}}
               ]},
              {:tools, [{"shell", %{"command" => "sleep 30"}}]},
              {:tools, [{"shell", %{"command" => "sleep 30"}}]}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "build a tree")

      child_path = await_delegation_path(session.id, "general")
      await_subtree_size(session.id, child_path, 3)

      pids = AgentNode.descendants(session.id, child_path)
      assert length(pids) >= 4

      node_pid = Registry.whereis({:node, session.id, child_path})
      ref = Process.monitor(node_pid)
      Process.exit(node_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^node_pid, _}, 2_000

      # Registry entries and the processes themselves must both be gone: an entry
      # without a process, or the reverse, would each be a leak.
      assert await_subtree_gone(session.id, child_path, pids, 2_000),
             "subtree under #{inspect(child_path)} outlived its Node"
    end
  end

  # A finished subagent kept its process, and with it its whole conversation, until its
  # session's tree stopped (#171). What it had to say is its delegation's result and its own
  # log, and nothing addresses a finished child by its process, so its parent stops it once
  # it has the result.
  describe "a subagent that has reported" do
    test "is stopped, so a session holds only the children still at work", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               Enum.map(1..4, &{"delegate", %{"agent" => "general", "task" => "quick #{&1}"}}) ++
                 [{"delegate", %{"agent" => "lingering", "task" => "slow"}}]},
              {:text, "all five came back"}
            ],
            "general" => List.duplicate({:tools, [{"finish", %{"summary" => "quick"}}]}, 4),
            "lingering" => [
              {:tools,
               [{"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 1_500}}]},
              {:tools, [{"finish", %{"summary" => "slow"}}]}
            ]
          },
          definitions: definitions_with(["lingering"])
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "five things, one slow")

      await_results(sid, "quick", 4)
      [lingering] = children_of(sid, "lingering")

      # Four have reported and the fifth is still counting: the fifth is all that is left.
      assert eventually(fn -> Troupe.agent_tree(sid) == [["root"], lingering] end)
      assert eventually(fn -> length(AgentNode.descendants(sid, ["root"])) == 8 end)
      assert %{active: 1} = DynamicSupervisor.count_children(Registry.children_sup(sid, ["root"]))

      await_root_idle(sid, 10_000)

      assert eventually(fn -> Troupe.agent_tree(sid) == [["root"]] end)
      assert eventually(fn -> length(AgentNode.descendants(sid, ["root"])) == 4 end)
      assert %{active: 0} = DynamicSupervisor.count_children(Registry.children_sup(sid, ["root"]))

      # Each finished before its parent took its result, so nothing was cut off.
      for path <- children_of(sid, "general") ++ children_of(sid, "lingering") do
        assert Troupe.snapshot(sid, path) == {:error, :no_agent}
        assert_reported_before_taken(sid, path)
      end
    end

    test "does not pile up over a session's delegations", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" =>
              List.duplicate(
                {:tools, [{"delegate", %{"agent" => "general", "task" => "one more"}}]},
                5
              ) ++
                [{:text, "five in a row"}],
            "general" => List.duplicate({:tools, [{"finish", %{"summary" => "done one"}}]}, 5)
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "delegate five times over")
      await_root_idle(sid, 10_000)

      paths = children_of(sid, "general")
      assert length(paths) == 5
      assert eventually(fn -> Troupe.agent_tree(sid) == [["root"]] end)
      assert eventually(fn -> length(AgentNode.descendants(sid, ["root"])) == 4 end)
      Enum.each(paths, &assert_reported_before_taken(sid, &1))
    end

    # Everything that reads a finished child reads its log: the parent's conversation, a
    # restart's replay of it, and the child's own part of the log.
    test "is still read from its log, before and after its parent restarts", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look"}}]},
              {:text, "it found it"}
            ],
            "general" => [
              {:text_and_tools, "found it in lib/a.ex", [{"finish", %{"summary" => "lib/a.ex"}}]}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "delegate it")
      await_root_idle(sid)

      [child] = children_of(sid, "general")
      assert eventually(fn -> Troupe.agent_tree(sid) == [["root"]] end)

      child_log = sid |> Troupe.events() |> Enum.filter(&(&1.agent == child))
      assert %{type: "agent_started"} = List.first(child_log)

      assert %{type: "agent_done", data: %{"reason" => "finished", "summary" => "lib/a.ex"}} =
               List.last(child_log)

      before = Troupe.snapshot(sid).conversation

      assert Enum.any?(before, fn message ->
               Enum.any?(
                 List.wrap(message.content),
                 &match?(%ToolResult{content: "lib/a.ex"}, &1)
               )
             end)

      calls = Fake.call_count(fake)

      agent = Registry.agent_pid(sid, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
      assert eventually(fn -> Registry.agent_pid(sid, ["root"]) not in [nil, agent] end)

      # The replay is the conversation it had, and it neither delegates again nor asks the
      # child for anything.
      assert eventually(fn -> match?(%{state: :idle}, Troupe.snapshot(sid)) end)
      assert Troupe.snapshot(sid).conversation == before
      assert Fake.call_count(fake) == calls
      assert Troupe.agent_tree(sid) == [["root"]]
      assert [_one] = events_of_type(sid, "delegation_started")
    end
  end

  describe "depth cap" do
    test "delegating past the cap is an error result, not a crash", context do
      %{session: session} =
        start_session(context,
          config_overrides: [max_depth: 1],
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "go deeper"}}]},
              {:text, "root done"}
            ],
            # The child is at depth 1 and may not delegate further.
            "general" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "too deep"}}]},
              {:tools, [{"finish", %{"summary" => "could not delegate further"}}]}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "recurse")
      await_root_idle(session.id, 15_000)

      rejected =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.find(&(&1.data["content"] =~ "Delegation depth limit"))

      assert rejected, "expected a depth-limit error result"
      assert Troupe.agent_tree(session.id) |> length() <= 2
    end
  end

  defp definitions_with_doomed, do: definitions_with(["doomed"])

  defp definitions_with(names) do
    base = Definitions.load(System.tmp_dir!())

    extra =
      Enum.map(names, fn name ->
        {:ok, definition} = Definition.parse(name, "---\nmode: subagent\n---\n#{name}", :project)
        definition
      end)

    Definitions.from_list(Definitions.all(base) ++ extra)
  end

  defp children_of(session_id, agent) do
    session_id
    |> events_of_type("delegation_started")
    |> Enum.filter(&(&1.data["agent"] == agent))
    |> Enum.map(& &1.data["child_path"])
  end

  # Waits for `count` delegations to have come back with `content`.
  defp await_results(session_id, content, count, timeout \\ 5_000) do
    done? = fn ->
      session_id
      |> events_of_type("tool_call_completed")
      |> Enum.count(&(&1.data["name"] == "delegate" and &1.data["content"] == content))
      |> Kernel.>=(count)
    end

    assert eventually(done?, timeout),
           "#{count} delegations never came back with #{inspect(content)}"
  end

  # The child wrote its `agent_done` before its parent wrote the result it had been handed,
  # so a parent that stops the child the moment it has the result cuts nothing off.
  defp assert_reported_before_taken(session_id, child_path) do
    events = Troupe.events(session_id)

    [started] =
      Enum.filter(
        events,
        &(&1.type == "delegation_started" and &1.data["child_path"] == child_path)
      )

    [done] = Enum.filter(events, &(&1.type == "agent_done" and &1.agent == child_path))

    [taken] =
      Enum.filter(
        events,
        &(&1.type == "tool_call_completed" and &1.agent == started.agent and
            &1.data["call_id"] == started.data["call_id"])
      )

    assert done.seq < taken.seq
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

  # The root is idle only once every delegation has come back, so filtering by
  # agent_path is what makes this different from `await_state`.
  defp await_root_idle(session_id, timeout \\ 10_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "agent_state", agent: ["root"], data: %{"state" => "idle"}}} ->
        if Troupe.snapshot(session_id).outstanding == [] do
          :ok
        else
          await_root_idle(session_id, timeout)
        end

      _other ->
        await_root_idle(session_id, timeout)
    after
      timeout -> raise "timed out waiting for the root agent to go idle"
    end
  end

  # Persisted events reach subscribers in the shape the log wrote them, so the data
  # here is string-keyed JSON rather than the agent's internal terms.
  defp await_delegation_path(session_id, agent, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "delegation_started", data: %{"agent" => ^agent, "child_path" => path}}} ->
        path

      _other ->
        await_delegation_path(session_id, agent, timeout)
    after
      timeout -> raise "timed out waiting for a delegation to #{agent}"
    end
  end

  # A child Node is :temporary, so once it exceeds its restart intensity it is gone
  # for good. Reaching that state means killing the agent faster than the Node can
  # restart it — and waiting on the *Node*, because right after a kill the restarted
  # agent has not re-registered yet and looking for it would end the loop early.
  defp kill_until_gone(session_id, path, attempts \\ @kill_attempts) do
    node_pid = Registry.whereis({:node, session_id, path})
    assert is_pid(node_pid), "no Node registered for #{inspect(path)}"
    ref = Process.monitor(node_pid)
    do_kill_until_gone(session_id, path, ref, node_pid, attempts)
  end

  defp do_kill_until_gone(_session_id, path, _ref, _node_pid, 0) do
    flunk("Node for #{inspect(path)} never exceeded its restart intensity")
  end

  defp do_kill_until_gone(session_id, path, ref, node_pid, attempts) do
    receive do
      {:DOWN, ^ref, :process, ^node_pid, _reason} -> :ok
    after
      0 ->
        # Only the Node's own `:DOWN` ends this loop. An agent missing from the
        # registry is not the same thing — a child that answered and finished leaves
        # one too — and taking it for the end would let a *successful* delegation pass
        # for a dead one, which is the opposite of what this test is about.
        case await_agent(session_id, path, 1_000) do
          nil -> :not_registered
          pid -> Process.exit(pid, :kill)
        end

        receive do
          {:DOWN, ^ref, :process, ^node_pid, _reason} -> :ok
        after
          25 -> do_kill_until_gone(session_id, path, ref, node_pid, attempts - 1)
        end
    end
  end

  defp await_agent(session_id, path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_agent(session_id, path, deadline)
  end

  defp do_await_agent(session_id, path, deadline) do
    case Registry.whereis({:agent, session_id, path}) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline,
          do: nil,
          else: do_await_agent(session_id, path, deadline)

      pid ->
        pid
    end
  end

  defp await_subtree_size(session_id, path, size, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_subtree_size(session_id, path, size, deadline)
  end

  defp do_await_subtree_size(session_id, path, size, deadline) do
    current = length(Registry.agent_paths_under(session_id, path))

    cond do
      current >= size -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> do_await_subtree_size(session_id, path, size, deadline)
    end
  end

  defp await_subtree_gone(session_id, path, pids, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_subtree_gone(session_id, path, pids, deadline)
  end

  defp do_await_subtree_gone(session_id, path, pids, deadline) do
    registry_clear? = Registry.agent_paths_under(session_id, path) == []
    processes_clear? = Enum.all?(pids, &(not Process.alive?(&1)))

    cond do
      registry_clear? and processes_clear? -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> do_await_subtree_gone(session_id, path, pids, deadline)
    end
  end
end
