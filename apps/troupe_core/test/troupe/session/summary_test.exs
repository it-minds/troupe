defmodule Troupe.Session.SummaryTest do
  @moduledoc """
  The projection a fleet view lives on.

  Two things matter: that it says what a session is doing, and that it says it rarely.
  A `summary` subscription exists to be cheaper than `detail`, and a projection that
  republished on every model delta would cost more than the thing it replaces.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Log
  alias Troupe.Session.Summary

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))

  test "folds a session into a compact snapshot", context do
    %{session: session} =
      start_session(context,
        steps: [
          {:tools,
           [
             {"todo_write",
              %{
                "items" => [
                  %{"id" => "a", "content" => "read the failing test", "status" => "in_progress"},
                  %{"id" => "b", "content" => "fix it", "status" => "pending"}
                ]
              }}
           ]},
          {:text, "had a look"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "have a look")
    await_state(session.id, [:idle, :done], 10_000)

    # A projection is a subscriber like any other, and the order `Events.publish/2`
    # reaches its subscribers in is not defined — so seeing the transition ourselves says
    # nothing about whether the projection has folded it yet. Waited for rather than
    # assumed, because the alternative is a test that passes most of the time.
    snapshot = await_snapshot(session.id, &(&1["agents"]["root"]["state"] in ["idle", "done"]))

    assert snapshot["todo"] == "read the failing test"
    assert snapshot["agents"]["root"]["state"] in ["idle", "done"]
    assert snapshot["agents"]["root"]["profile"] == "build"
    assert snapshot["tool"] == nil, "a finished tool should not still be shown as running"
    assert snapshot["tokens"] > 0
    assert snapshot["approvals"] == []
    assert snapshot["error"] == nil
  end

  defp await_snapshot(session_id, predicate, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_snapshot(session_id, predicate, deadline)
  end

  defp do_await_snapshot(session_id, predicate, deadline) do
    snapshot = Summary.snapshot(session_id)

    cond do
      predicate.(snapshot) -> snapshot
      System.monotonic_time(:millisecond) >= deadline -> snapshot
      true -> do_await_snapshot(session_id, predicate, deadline)
    end
  end

  test "counts an event once when it is in the log and in the mailbox at the same time",
       context do
    # The race that made `UsageFlowTest` fail intermittently on CI with a cost of exactly
    # double. A projection must subscribe *before* it replays, or it misses what happens in
    # between — and an event that is then in both places was folded twice, once from each.
    #
    # Made deterministic here by doing to a fresh projection exactly what the race does:
    # replaying a log that already holds a sealed event, and handing the same event to it
    # again as a live message.
    %{session: session} = start_session(context, steps: [{:text, "done"}])

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_state(session.id, [:idle, :done], 10_000)

    # Whatever the turn cost, from the projection that folded it the ordinary way.
    settled = await_snapshot(session.id, &(&1["cost_micros"] > 0))
    cost = settled["cost_micros"]

    # A second projection over the same log: same value, because the log is the same.
    # Started unnamed: `start_link/1` registers under the session's own name, and what is
    # wanted here is a second projection over the same log rather than a replacement.
    {:ok, replayed} = GenServer.start_link(Summary, session_id: session.id)
    assert :sys.get_state(replayed).snapshot["cost_micros"] == cost

    # And now the race itself. Every durable event the log holds, delivered again as if it
    # had arrived from the subscription during the replay.
    for event <- Log.replay(session.id) do
      send(replayed, {:troupe_event, session.id, event})
    end

    # Unchanged. A sequence the replay already covered is one this projection has already
    # accounted for — which is the whole of the fix, and without it this is `2 * cost`.
    assert :sys.get_state(replayed).snapshot["cost_micros"] == cost
  end

  test "publishes diffs, and no more than four a second", context do
    %{session: session} = start_session(context, steps: [{:text, "one"}, {:text, "two"}])

    Troupe.subscribe(session.id)

    started = System.monotonic_time(:millisecond)
    Troupe.send_input(session.id, "go")
    await_state(session.id, [:idle, :done], 10_000)
    Troupe.send_input(session.id, "again")
    await_state(session.id, [:idle, :done], 10_000)
    elapsed = System.monotonic_time(:millisecond) - started

    diffs = collect_diffs()

    assert diffs != [], "the projection published nothing at all"

    # Four a second, with one allowed for the boundary: the turns here change the
    # projection far more often than that.
    allowed = ceil(elapsed / 250) + 1
    assert length(diffs) <= allowed, "#{length(diffs)} diffs in #{elapsed}ms"

    # A diff carries what changed, not the whole snapshot every time.
    assert Enum.all?(diffs, &is_map(&1.data["changed"]))
    assert Enum.any?(diffs, &Map.has_key?(&1.data["changed"], "agents"))
  end

  test "an approval shows up and goes away again", context do
    %{session: session} =
      start_session(context,
        config_overrides: [auto_approve: false],
        steps: [{:tools, [{"needs_approval", %{"note" => "hi"}}]}, {:text, "done"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "ask me")

    request = await_event(session.id, :approval_requested, 10_000)
    call_id = request.data["call_id"]

    await(fn -> Summary.snapshot(session.id)["approvals"] == [call_id] end)

    Troupe.approve(session.id, call_id, :allow)
    await_state(session.id, [:idle, :done], 10_000)

    assert Summary.snapshot(session.id)["approvals"] == []
  end

  test "an approval goes away when its turn is cancelled", context do
    %{session: session} =
      start_session(context,
        config_overrides: [auto_approve: false],
        steps: [{:tools, [{"needs_approval", %{"note" => "hi"}}]}, {:text, "never asked"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "ask me")

    request = await_event(session.id, :approval_requested, 10_000)
    call_id = request.data["call_id"]

    # Published before the cancel, so that the diff after it has something to take back.
    await_diff(&(&1["approvals"] == [call_id]))

    Troupe.cancel(session.id)
    await_diff(&(&1["approvals"] == []))
    assert Summary.snapshot(session.id)["approvals"] == []
  end

  # Logs real sessions wrote against the scripted model, one per way an approval can
  # end, so the fold is held to what the agent actually writes (#142): a cancel closes
  # each call it stops with a `tool_call_completed` and then says `cancelled`; a tool that
  # timed out waiting is closed the same way; a subagent the cancel took down says
  # nothing at all. `subagent_cancelled` is that last one, and `open` stops mid-wait.
  describe "an approval in a recorded log" do
    test "is not pending once its turn was cancelled or its tool timed out" do
      for name <- ~w(cancelled timed_out subagent_cancelled) do
        folded = recorded(name)
        assert folded["approvals"] == [], "#{name} still has #{inspect(folded["approvals"])}"

        # And the map is the one it was before the projection kept track of who asked,
        # which is what keeps every recorded fixture hash where it was.
        refute Map.has_key?(folded, "approval_agents"), name
      end
    end

    test "is closed by its decision, and pending while nobody has answered it" do
      assert recorded("decided")["approvals"] == []

      open = recorded("open")
      assert [call_id] = open["approvals"]
      assert open["approval_agents"] == %{call_id => "root"}
    end
  end

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
    |> Enum.reduce(Summary.empty(), &Summary.fold(&2, &1))
  end

  # The next diff whose change matches, checking on the way that none of them says which
  # agent asked for an approval: that is the projection's own bookkeeping.
  defp await_diff(predicate) do
    receive do
      {:troupe_event, _session_id, %Event{type: "summary_diff", data: %{"changed" => changed}}} ->
        refute Map.has_key?(changed, "approval_agents")
        if predicate.(changed), do: changed, else: await_diff(predicate)

      {:troupe_event, _session_id, _event} ->
        await_diff(predicate)
    after
      5_000 -> flunk("no matching summary diff")
    end
  end

  defp collect_diffs(acc \\ []) do
    receive do
      {:troupe_event, _session_id, %Event{type: "summary_diff"} = event} ->
        collect_diffs([event | acc])

      {:troupe_event, _session_id, _event} ->
        collect_diffs(acc)
    after
      400 -> Enum.reverse(acc)
    end
  end

  defp await(predicate, attempts \\ 200) do
    cond do
      predicate.() -> :ok
      attempts > 0 -> Process.sleep(25) && await(predicate, attempts - 1)
      true -> flunk("condition never held")
    end
  end
end
