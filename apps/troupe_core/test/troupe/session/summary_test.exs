defmodule Troupe.Session.SummaryTest do
  @moduledoc """
  The projection a fleet view lives on.

  Two things matter: that it says what a session is doing, and that it says it rarely.
  A `summary` subscription exists to be cheaper than `detail`, and a projection that
  republished on every model delta would cost more than the thing it replaces.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Summary

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
