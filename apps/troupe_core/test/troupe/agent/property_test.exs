defmodule Troupe.Agent.PropertyTest do
  @moduledoc """
  The agent's liveness invariant under adversarial input.

  The claim being checked is the one the state machine is designed around: whatever
  arrives, in whatever order, the agent neither crashes nor wedges — it always comes
  to rest in `:idle` or `:done`. That covers input racing a cancel, a profile switch
  mid-turn, and messages the protocol has never heard of.
  """

  use Troupe.SessionCase, async: true
  use ExUnitProperties

  alias Troupe.Agent.Server, as: AgentServer
  alias Troupe.Registry
  alias Troupe.Todo

  @actions [:input, :cancel, :switch_plan, :switch_build, :unknown, :todo_edit, :bad_approval]

  property "any interleaving of input, cancel, profile switches and junk leaves the agent live and at rest",
           context do
    check all(
            actions <- list_of(member_of(@actions), min_length: 1, max_length: 14),
            max_runs: 25
          ) do
      %{session: session} =
        start_session(context,
          # A script long enough that the agent always has something to do, with a
          # mix of tool turns and plain answers so cancels land in both :thinking
          # and :acting.
          steps: script(),
          default: {:text, "settled"},
          delay_ms: 2
        )

      Troupe.subscribe(session.id)
      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)

      Enum.each(actions, &perform(session.id, &1))

      # Cancel last so the machine is not left mid-turn by construction; the point of
      # the property is what the *interleaving* did, not that a busy agent is idle.
      # Input that was postponed is deliberately not discarded by a cancel, so the
      # agent may legitimately start another turn after this before settling.
      Troupe.cancel(session.id)

      final = await_settled(session.id, agent, deadline(10_000))
      assert final in [:idle, :done], "agent never came to rest (last seen #{inspect(final)})"
      assert Process.alive?(agent), "agent died"
      refute_received {:DOWN, ^ref, :process, ^agent, _}
      Process.demonitor(ref, [:flush])

      Troupe.unsubscribe(session.id)
      Troupe.stop_session(session.id)
    end
  end

  defp script do
    [
      {:tools, [{"todo_read", %{}}]},
      {:text, "one"},
      {:tools, [{"list_files", %{"pattern" => "**/*"}}, {"todo_read", %{}}]},
      {:text, "two"},
      {:tools,
       [{"todo_write", %{"items" => [%{"id" => "x", "content" => "y", "status" => "pending"}]}}]},
      {:text, "three"}
    ]
  end

  defp perform(session_id, :input), do: Troupe.send_input(session_id, "do something")
  defp perform(session_id, :cancel), do: Troupe.cancel(session_id)
  defp perform(session_id, :switch_plan), do: Troupe.switch_profile(session_id, "plan")
  defp perform(session_id, :switch_build), do: Troupe.switch_profile(session_id, "build")

  defp perform(session_id, :unknown) do
    # Three shapes of message the protocol has no clause for: a bare atom, a tagged
    # tuple carrying a stale ref, and a well-known tag with a nonsense payload.
    agent = Registry.agent_pid(session_id, ["root"])
    send(agent, :nonsense)
    send(agent, {:llm_done, make_ref(), %{not: "a response"}})
    send(agent, {:tool_result, "no-such-call", %{}})
  end

  defp perform(session_id, :todo_edit) do
    Troupe.send_input(session_id, Todo.Edit.add("from the tui"), :tui_todo_edit)
  end

  defp perform(session_id, :bad_approval) do
    Troupe.approve(session_id, "no-such-call", :allow)
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  # "At rest" means idle or done *and staying there*: postponed input is replayed on
  # the next state change, so a single glimpse of :idle proves nothing. This waits on
  # state events rather than sleeping, and re-checks the agent directly whenever the
  # event stream goes quiet.
  defp await_settled(session_id, agent, deadline) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        :never_settled

      settled?(agent) ->
        confirm_settled(session_id, agent, deadline)

      true ->
        receive do
          {:troupe_event, ^session_id, %Event{type: "agent_state", agent: ["root"]}} -> :ok
        after
          250 -> :ok
        end

        await_settled(session_id, agent, deadline)
    end
  end

  # A settled agent stays settled: any transition out of idle/done within the window
  # means the run is not over, so go back to waiting.
  defp confirm_settled(session_id, agent, deadline) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "agent_state", agent: ["root"], data: %{"state" => next}}}
      when next not in ["idle", "done"] ->
        await_settled(session_id, agent, deadline)
    after
      100 -> AgentServer.snapshot(agent).state
    end
  end

  defp settled?(agent), do: AgentServer.snapshot(agent).state in [:idle, :done]
end
