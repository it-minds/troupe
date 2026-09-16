defmodule Troupe.Session.UnattendedApprovalsTest do
  @moduledoc """
  An `ask` tool in a session nobody is attached to.

  `approvals: :deny` is what a triggered session runs under: the request and the
  refusal both land in the log, the actor is the system because no person decided, and
  the model hears a result it can act on rather than a hang.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Approvals

  # Polled, because what is under test is a thing that must *happen* rather than a thing
  # that is already there, and every `await_` here is satisfied by the past.
  defp eventually(check, deadline \\ 5_000) do
    cond do
      check.() ->
        :ok

      deadline <= 0 ->
        flunk("it did not happen")

      true ->
        Process.sleep(50)
        eventually(check, deadline - 50)
    end
  end

  test "an unattended session is told no at once, durably, by the system", context do
    %{session: session} =
      start_session(context,
        config_overrides: [auto_approve: false, approvals: :deny],
        steps: [
          {:tools, [{"needs_approval", %{"note" => "nobody home"}}]},
          {:text, "carried on without it"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "try it")
    await_state(session.id, [:idle], 10_000)

    [requested] = events_of_type(session.id, "approval_requested")
    [decided] = events_of_type(session.id, "approval_decided")

    assert requested.data["tool"] == "needs_approval"
    assert decided.data["call_id"] == requested.data["call_id"]
    assert decided.data["decision"] == "deny"
    assert decided.actor.kind == :system

    [completed] = events_of_type(session.id, "tool_call_completed")
    refute completed.data["ok"]
    assert completed.data["content"] =~ "unattended"
    assert completed.data["content"] =~ "needs_approval"

    # Nothing is left waiting for a person who is not coming.
    assert Approvals.pending(session.id) == []
  end

  test "the default still waits for a person", context do
    %{session: session} =
      start_session(context,
        config_overrides: [auto_approve: false],
        steps: [{:tools, [{"needs_approval", %{}}]}, {:text, "done"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "ask")
    await_event(session.id, :approval_requested)

    assert [_pending] = Approvals.pending(session.id)
    assert events_of_type(session.id, "approval_decided") == []
  end

  describe "a platform that keeps the permission rules" do
    test "answers this call and creates nothing standing", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false, managed_permission_rules_only: true],
          steps: [
            {:tools, [{"needs_approval", %{"n" => 1}}]},
            {:tools, [{"needs_approval", %{"n" => 2}}]},
            {:text, "done"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "ask")
      await_event(session.id, :approval_requested)

      [first] = Approvals.pending(session.id)
      Approvals.decide(session.id, first.call_id, :allow_session, nil)

      # The call in front of the person is allowed, and the standing rule they asked for
      # is not created: the second call asks again. A session that could grant itself a
      # blanket permission is a session deciding what it may do, which is the thing this
      # switch is for.
      #
      # Counted rather than awaited: `await_event` is satisfied by the request that is
      # already in the log, so it would pass whether or not a second one ever came.
      eventually(fn -> length(events_of_type(session.id, "approval_requested")) == 2 end)
      assert [second] = Approvals.pending(session.id)
      refute second.call_id == first.call_id

      # And the log says `allow`, not `allow_session`. An event naming a standing
      # permission beside a session that has none would be a log disagreeing with itself.
      [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["decision"] == "allow"
    end

    test "without it, one allow_session covers the next call", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [
            {:tools, [{"needs_approval", %{"n" => 1}}]},
            {:tools, [{"needs_approval", %{"n" => 2}}]},
            {:text, "done"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "ask")
      await_event(session.id, :approval_requested)

      [first] = Approvals.pending(session.id)
      Approvals.decide(session.id, first.call_id, :allow_session, nil)

      await_state(session.id, [:idle], 10_000)

      # The positive beside the negative, in the same file: without both, a switch that
      # did nothing at all would pass the test above.
      assert length(events_of_type(session.id, "approval_requested")) == 1
      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["decision"] == "allow_session"
    end
  end
end
