defmodule Troupe.Agent.DelegationTest do
  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Agent.Node, as: AgentNode

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

  defp definitions_with_doomed do
    base = Definitions.load(System.tmp_dir!())
    {:ok, doomed} = Definition.parse("doomed", "---\nmode: subagent\n---\nfail", :project)
    Definitions.from_list(Definitions.all(base) ++ [doomed])
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
