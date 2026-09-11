defmodule Troupe.Worker.ApprovalDormancyTest do
  @moduledoc """
  An approval asked before a session went to sleep, and answered days later.

  This is the case that makes approvals durable events rather than a message on a wire.
  The person who has to answer may be asleep, on another continent, or waiting for
  someone else to decide; the session must be able to go dormant with the question
  outstanding, come back on a different pod, and carry on from the call that was waiting
  — not from an error saying it was interrupted.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Protocol.Event
  alias Troupe.Session.Approvals

  @moduletag timeout: 180_000

  test "survives dormancy and continues from the resolved call", context do
    context = requires_tier(context)

    fake =
      start_supervised!(
        {Fake,
         steps: [
           {:tools, [{"needs_approval", %{"note" => "the thing that had to wait"}}]},
           {:text, "carried on"}
         ],
         default: {:text, "done"}}
      )

    assert {:ok, _} = activate(context, fake: fake, config_overrides: auto_approve_off(context))

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "do the thing")

    requested = await_event(context.session_id, "approval_requested")
    call_id = requested.data["call_id"]
    assert requested.data["tool"] == "needs_approval"

    # Pending approvals do not block dormancy: they are durable events and survive it.
    assert {:ok, sealed} = Sessions.dormant(context.session_id)
    assert Sessions.whereis(context.session_id) == nil

    sealed_events = sealed_events(context)
    assert Enum.any?(sealed_events, &(&1["type"] == "approval_requested"))

    # Three days pass. Nothing is running anywhere; the question is in object storage.
    assert {:ok, _} = activate(context, fake: fake, epoch: 2, config_overrides: auto_approve_off(context))

    Troupe.subscribe(context.session_id)

    # The call that was waiting is asked again rather than closed off as interrupted,
    # which is what puts it back in front of whoever is going to answer.
    reasked = await_pending(context.session_id)
    assert reasked.call_id == call_id
    assert reasked.tool == "needs_approval"

    completed = Troupe.replay_from(context.session_id, 0) |> Enum.filter(&(&1.type == "tool_call_completed"))
    refute Enum.any?(completed, &(&1.data["content"] =~ "interrupted"))

    # Three days later, somebody says yes.
    Troupe.approve(context.session_id, call_id, :allow, %Event.Actor{
      kind: :user,
      subject: "ada@example.test",
      display_name: "Ada"
    })

    # And the turn continues from there: the tool runs, its result goes back to the
    # model, and the model answers.
    result = await_event(context.session_id, "tool_call_completed")
    assert result.data["ok"]
    assert result.data["content"] =~ "the thing that had to wait"

    await_done(context.session_id, 15_000)

    events = Troupe.replay_from(context.session_id, 0)
    assert Enum.any?(events, &(&1.type == "approval_decided" and &1.data["call_id"] == call_id))
    assert :ok = Event.verify(events)
    assert sealed.sealed_through > 0
  end

  test "an approval answered before dormancy is not asked again", context do
    context = requires_tier(context)

    fake =
      start_supervised!(
        {Fake,
         steps: [
           {:tools, [{"needs_approval", %{"note" => "already agreed"}}]},
           {:text, "carried on"}
         ],
         default: {:text, "done"}}
      )

    assert {:ok, _} = activate(context, fake: fake, config_overrides: auto_approve_off(context))

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "do the thing")

    requested = await_event(context.session_id, "approval_requested")
    Troupe.approve(context.session_id, requested.data["call_id"], :allow)
    await_done(context.session_id, 15_000)

    assert {:ok, _} = Sessions.dormant(context.session_id)
    assert {:ok, _} = activate(context, fake: fake, epoch: 2, config_overrides: auto_approve_off(context))

    # The gate read its decisions back from the log, so nothing is outstanding and
    # nobody is asked a question they have already answered.
    assert Approvals.pending(context.session_id) == []

    asked = Troupe.replay_from(context.session_id, 0) |> Enum.count(&(&1.type == "approval_requested"))
    assert asked == 1
  end

  defp auto_approve_off(context) do
    [
      provider: "fake",
      model: "fake-model",
      auto_approve: false,
      state_dir: context.state_dir
    ]
  end

  defp await_event(session_id, type, timeout \\ 15_000) do
    receive do
      {:troupe_event, ^session_id, %Event{type: ^type} = event} -> event
      {:troupe_event, ^session_id, _other} -> await_event(session_id, type, timeout)
    after
      timeout -> flunk("no #{type} within #{timeout}ms")
    end
  end

  defp await_pending(session_id) do
    eventually(fn ->
      case Approvals.pending(session_id) do
        [request | _] -> request
        [] -> nil
      end
    end)
  end
end
