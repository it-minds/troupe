defmodule Troupe.Session.UnattendedApprovalsTest do
  @moduledoc """
  An `ask` tool in a session nobody is attached to.

  `approvals: :deny` is what a triggered session runs under: the request and the
  refusal both land in the log, the actor is the system because no person decided, and
  the model hears a result it can act on rather than a hang.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Approvals

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
end
