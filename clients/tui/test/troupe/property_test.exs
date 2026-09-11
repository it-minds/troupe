defmodule Troupe.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Troupe.TestHelpers

  alias Troupe.Session

  # Done item 11
  property "random interleavings never crash a branch or the Dispatcher; branches end idle or done" do
    op =
      one_of([
        constant(:dispatch),
        tuple({constant(:input), string(:printable, min_length: 1, max_length: 10)}),
        constant(:cancel),
        constant(:dismiss),
        tuple({constant(:switch), member_of(["code", "plan", "ask", "nope"])}),
        tuple({constant(:unknown), term()}),
        constant(:unknown_dispatcher),
        constant(:approve_all)
      ])

    check all(ops <- list_of(op, min_length: 3, max_length: 25), max_runs: 12) do
      ws = tmp_workspace(%{"f.txt" => "x"})

      fallback = fn req ->
        case rem(length(req.messages), 4) do
          0 ->
            {:tool, "read_file", %{"path" => "f.txt"}}

          1 ->
            {:tools,
             [
               {"shell", %{"command" => "echo hi"}},
               {"todo_write",
                %{"items" => [%{"id" => "1", "content" => "c", "status" => "pending"}]}}
             ]}

          2 ->
            {:tool, "write_file", %{"path" => "out.txt", "content" => "y"}}

          _ ->
            {:finish, "ok"}
        end
      end

      {sid, _, _} = start_session!(workspace: ws, fallback: fallback)
      dispatcher = Session.whereis(sid, :dispatcher)

      Enum.each(ops, fn op -> run_op(sid, op) end)

      # quiesce: no branch may be left thinking/acting forever with a script that always terminates,
      # except branches waiting on approvals, which we answer.
      eventually(
        fn ->
          for %{call_id: id} <- Session.Approvals.pending(sid), do: Troupe.approve(sid, id, :allow)
          Enum.all?(live_agents(sid), fn pid -> agent_state(pid) in [:idle, :done] end)
        end,
        20_000,
        50
      )

      assert Process.alive?(dispatcher), "dispatcher crashed"
      assert Session.whereis(sid, :dispatcher) == dispatcher
      refute Enum.any?(Troupe.windows(sid), &(&1.state == :failed_unread))
      Troupe.stop_session(sid)
    end
  end

  defp run_op(sid, :dispatch), do: Troupe.dispatch(sid, "code", "task")
  defp run_op(sid, {:input, text}), do: with_branch(sid, &Troupe.send_input(sid, &1, text))
  defp run_op(sid, :cancel), do: with_branch(sid, &Troupe.cancel(sid, &1))
  defp run_op(sid, :dismiss), do: with_branch(sid, &Troupe.dismiss(sid, &1))
  defp run_op(sid, {:switch, name}), do: with_branch(sid, &Troupe.switch_profile(sid, &1, name))

  defp run_op(sid, {:unknown, term}),
    do: with_branch(sid, fn p -> if pid = Troupe.agent_pid(sid, p), do: send(pid, term) end)

  defp run_op(sid, :unknown_dispatcher),
    do: send(Session.whereis(sid, :dispatcher), {:garbage, make_ref()})

  defp run_op(sid, :approve_all),
    do: for(%{call_id: id} <- Session.Approvals.pending(sid), do: Troupe.approve(sid, id, :deny))

  defp with_branch(sid, fun) do
    case Troupe.windows(sid) do
      [] -> :ok
      windows -> fun.(Enum.random(windows).agent_path)
    end
  end

  defp agent_state(pid) do
    Troupe.Agent.Server.current_state(pid)
  catch
    :exit, _ -> :done
  end

  defp live_agents(sid) do
    Registry.select(Troupe.Registry, [{{{sid, {:agent, :"$1"}}, :"$2", :_}, [], [:"$2"]}])
  end
end
