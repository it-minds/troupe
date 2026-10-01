defmodule Troupe.Worker.StoppedTurnTest do
  @moduledoc """
  A turn the harness stopped, as the plane is told it (issue #320, Decision 750).

  The failure guard ends a turn `tool_failures` (Decision 687), and a root that kept
  crashing ends one `agent_failed` and takes its session down (Decision 727). Both leave
  the root at rest, and the plane read that as a finished turn: the row said `idle` with
  no reason, and a trigger's run looked like one that had done its work. The reason now
  goes with the status until another turn starts, and a session whose tree stopped under
  its manager goes to sleep then, rather than when the idle timer next looks.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Session.Log

  @moduletag timeout: 180_000

  test "a turn the failure guard stopped is reported with its reason until the next one starts",
       context do
    context = requires_tier(context)
    sid = context.session_id

    # Nobody to ask, so the guard's question is answered `stop` by the harness itself, as
    # it is for a trigger's session.
    fake = scripted(failing(12) ++ [{:text, "fine"}])

    assert {:ok, _} =
             activate(context,
               fake: fake,
               prompt: "read the file",
               report: reporter_to(self()),
               config_overrides: [approvals: :deny]
             )

    await_ended(sid)

    assert %{"status" => "idle", "failed_reason" => "tool_failures", "pending_questions" => 0} =
             last_status()

    # The person's next message starts a turn, and the reason is the last turn's, not this.
    Troupe.send_input(sid, "try something else")
    assert %{"status" => "idle", "failed_reason" => nil} = await_status(&cleared?/1)
  end

  test "a root that kept crashing is reported failed, and its session goes to sleep at once",
       context do
    context = requires_tier(context)
    sid = context.session_id

    assert {:ok, _} =
             activate(context, fake: scripted([{:text, "hello"}]), report: reporter_to(self()))

    :ok = run_turn(sid, "hi")

    # As `crash_loop_test.exs` does it: a goal the prompt cannot be built from and a turn
    # the model is owed, so every start again takes the turn up and crashes building its
    # request, until the Node gives up and the session stops.
    Log.append(sid, ["root"], :goal_set, %{"text" => %{"not" => "text"}})
    Log.append(sid, ["root"], :user_input, %{"source" => "user", "text" => "carry on"})
    Process.exit(Troupe.Registry.agent_pid(sid, ["root"]), :kill)

    {statuses, dormant} = reports_until_dormant(15_000)

    # Said while it happened, which is what tells a trigger's target, and again in the
    # last word the plane gets until the session wakes.
    assert Enum.any?(
             statuses,
             &(&1["failed_reason"] == "agent_failed" and &1["status"] == "idle")
           )

    assert %{"status" => "idle", "failed_reason" => "agent_failed"} = dormant

    # What it cost is what it cost before the tree went, not the nothing a projection that
    # has stopped answers.
    assert dormant["cost_micros"] > 0
    eventually(fn -> is_nil(Sessions.whereis(sid)) end)
  end

  test "a session woken after a failed turn says so until a turn starts", context do
    context = requires_tier(context)
    sid = context.session_id
    fake = scripted([{:text, "hello"}, {:text, "again"}])

    assert {:ok, _} = activate(context, fake: fake, report: reporter_to(self()))
    :ok = run_turn(sid, "hi")

    Log.append(sid, ["root"], :goal_set, %{"text" => %{"not" => "text"}})
    Log.append(sid, ["root"], :user_input, %{"source" => "user", "text" => "carry on"})
    Process.exit(Troupe.Registry.agent_pid(sid, ["root"]), :kill)
    {_statuses, _dormant} = reports_until_dormant(15_000)
    eventually(fn -> is_nil(Sessions.whereis(sid)) end)

    # Woken without a word from anybody: the failure is still the last thing that
    # happened to a turn, and the first report says so rather than clearing it.
    assert {:ok, _} = activate(context, fake: fake, epoch: 2, report: reporter_to(self()))
    assert %{"failed_reason" => "agent_failed"} = await_status()

    Troupe.clear_goal(sid)
    Troupe.send_input(sid, "again")
    assert %{"status" => "idle", "failed_reason" => nil} = await_status(&cleared?/1)
  end

  # -- helpers ----------------------------------------------------------------

  defp failing(n), do: List.duplicate({:tools, [{"read_file", %{"path" => "missing.txt"}}]}, n)

  # The next turn has run and rested on its own: a fake model answers at once, and the
  # debounce may fold the turn into the one report that says it is over.
  defp cleared?(report),
    do: report["status"] == "idle" and Map.fetch(report, "failed_reason") == {:ok, nil}

  defp scripted(steps) do
    start_supervised!(
      Supervisor.child_spec({Fake, steps: steps, default: {:text, "done"}},
        id: {Fake, System.unique_integer([:positive])}
      )
    )
  end

  # The turn is over when the log says so; the status reports about it are debounced, so
  # the last one is read once they have gone quiet.
  defp await_ended(session_id) do
    eventually(
      fn ->
        session_id
        |> Troupe.replay_from(0)
        |> Enum.any?(&(&1.type == "turn_ended" and &1.agent == ["root"]))
      end,
      15_000
    )
  end

  defp last_status(last \\ nil, quiet_ms \\ 1_000) do
    receive do
      {:sealed, %{"type" => "session.status"} = report} -> last_status(report, quiet_ms)
      {:sealed, _other} -> last_status(last, quiet_ms)
    after
      quiet_ms -> last || flunk("no session.status was reported")
    end
  end

  defp await_status(predicate \\ fn _ -> true end, timeout \\ 15_000) do
    receive do
      {:sealed, %{"type" => "session.status"} = report} ->
        if predicate.(report), do: report, else: await_status(predicate, timeout)

      {:sealed, _other} ->
        await_status(predicate, timeout)
    after
      timeout -> flunk("no matching session.status within #{timeout}ms")
    end
  end

  defp reports_until_dormant(timeout, statuses \\ []) do
    receive do
      {:sealed, %{"type" => "session.dormant"} = report} ->
        {Enum.reverse(statuses), report}

      {:sealed, %{"type" => "session.status"} = report} ->
        reports_until_dormant(timeout, [report | statuses])

      {:sealed, _other} ->
        reports_until_dormant(timeout, statuses)
    after
      timeout -> flunk("no session.dormant within #{timeout}ms of the session stopping")
    end
  end
end
