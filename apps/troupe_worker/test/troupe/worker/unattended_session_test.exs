defmodule Troupe.Worker.UnattendedSessionTest do
  @moduledoc """
  A session nobody is attached to: activated with a prompt, capped by terms, refused
  its approvals, and reported to the plane as it goes.

  These are the worker's half of remote triggers. The plane carries the prompt and the
  terms; what is checked here is that the pod does the first turn alone, does it once,
  and tells the plane enough to list the session without reading its log.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Session.Approvals

  @moduletag timeout: 180_000

  @prompt "update every dependency with a patch release"

  describe "a prompt through activation" do
    test "is the first input, once, however many times the session is activated", context do
      context = requires_tier(context)
      fake = scripted([{:text, "updated"}])

      assert {:ok, _} =
               activate(context,
                 fake: fake,
                 prompt: @prompt,
                 origin: %{"kind" => "trigger", "trigger" => "nightly-deps"}
               )

      await_responses(context.session_id, 1)

      events = Troupe.replay_from(context.session_id, 0)
      types = Enum.map(events, & &1.type)

      # The prompt went in as an input like any other and the model was asked once.
      assert [input] = Enum.filter(events, &(&1.type == "user_input"))
      assert input.data["text"] == @prompt
      input_at = Enum.find_index(types, &(&1 == "user_input"))
      request_at = Enum.find_index(types, &(&1 == "llm_request"))
      assert input_at < request_at
      assert Fake.call_count(fake) == 1

      [created] = Enum.filter(events, &(&1.type == "session_created"))
      assert created.data["kind"] == "team"
      assert created.data["origin"] == %{"kind" => "trigger", "trigger" => "nightly-deps"}

      # Asleep, and awake again with the same prompt: it is not repeated.
      assert {:ok, _} = Sessions.dormant(context.session_id)
      assert {:ok, _} = activate(context, fake: fake, epoch: 2, prompt: @prompt)

      Process.sleep(300)
      replayed = Troupe.replay_from(context.session_id, 0)
      assert Enum.count(replayed, &(&1.type == "user_input")) == 1
      assert Fake.call_count(fake) == 1
    end
  end

  describe "terms" do
    test "max_turns ends the session with the limit named", context do
      context = requires_tier(context)

      look = {:tools, [{"list_files", %{}}]}
      fake = scripted([look, look, {:text, "x"}])

      assert {:ok, _} =
               activate(context, fake: fake, prompt: "look around", terms: [max_turns: 1])

      await_type(context.session_id, "agent_done")

      [done] = Enum.filter(Troupe.replay_from(context.session_id, 0), &(&1.type == "agent_done"))
      assert done.data["reason"] == "budget_exhausted"
      assert done.data["limit"] == "max_turns"
      assert Fake.call_count(fake) == 1
    end

    test "approvals: deny answers no on the spot, with the system as the actor", context do
      context = requires_tier(context)

      ask = {:tools, [{"needs_approval", %{"note" => "nobody home"}}]}
      fake = scripted([ask, {:text, "did without it"}])

      assert {:ok, _} =
               activate(context,
                 fake: fake,
                 prompt: "do the thing",
                 terms: [approvals: :deny],
                 config_overrides: [auto_approve: false]
               )

      await_responses(context.session_id, 2)

      events = Troupe.replay_from(context.session_id, 0)
      [decided] = Enum.filter(events, &(&1.type == "approval_decided"))
      assert decided.data["decision"] == "deny"
      assert decided.data["tool"] == "needs_approval"
      assert decided.actor.kind == :system

      [completed] = Enum.filter(events, &(&1.type == "tool_call_completed"))
      refute completed.data["ok"]
      assert completed.data["content"] =~ "unattended"
      assert Approvals.pending(context.session_id) == []
    end
  end

  describe "status reporting" do
    test "the plane hears the lifecycle on change, debounced, and again at dormancy", context do
      context = requires_tier(context)
      ask = {:tools, [{"needs_approval", %{"note" => "wait for me"}}]}
      fake = scripted([ask, {:text, "thanks"}])

      assert {:ok, _} =
               activate(context,
                 fake: fake,
                 report: reporter_to(self()),
                 config_overrides: [auto_approve: false]
               )

      # The first report is where the session stands the moment it is up.
      first = await_status()
      assert first["session_id"] == context.session_id
      assert first["status"] == "idle"
      assert first["done_reason"] == nil
      assert first["pending_approvals"] == 0
      assert first["cost_micros"] == 0
      assert first["epoch"] == 1

      Troupe.subscribe(context.session_id)
      Troupe.send_input(context.session_id, "ask me something")

      waiting = await_status(&(&1["status"] == "waiting"))
      assert waiting["pending_approvals"] == 1

      [request] = Approvals.pending(context.session_id)
      Troupe.approve(context.session_id, request.call_id, :allow)
      await_done(context.session_id, 15_000)

      idle = await_status(&(&1["status"] == "idle" and &1["pending_approvals"] == 0))
      assert idle["pending_approvals"] == 0

      # No two reports for one session closer together than the debounce allows.
      gaps = status_gaps()
      assert Enum.all?(gaps, &(&1 >= 400)), "status reports too close together: #{inspect(gaps)}"

      # And the dormancy report says the same things, so the plane's last word on a
      # sleeping session is as complete as its first.
      assert {:ok, _} = Sessions.dormant(context.session_id)
      dormant = await_dormant()
      assert dormant["status"] == "idle"
      assert dormant["pending_approvals"] == 0
      assert Map.has_key?(dormant, "done_reason")
      assert Map.has_key?(dormant, "cost_micros")
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp scripted(steps) do
    start_supervised!({Fake, steps: steps, default: {:text, "done"}})
  end

  # A seeded turn starts inside activation, so the root's first `idle` transition is
  # published before the turn and cannot be waited on. The log can: the turn is over
  # when the model has answered as many times as the script says it should.
  defp await_responses(session_id, count) do
    eventually(
      fn ->
        Enum.count(Troupe.replay_from(session_id, 0), &(&1.type == "llm_response")) >= count
      end,
      15_000
    )
  end

  defp await_type(session_id, type) do
    eventually(fn -> Enum.any?(Troupe.replay_from(session_id, 0), &(&1.type == type)) end, 15_000)
  end

  defp await_status(predicate \\ fn _ -> true end, timeout \\ 15_000) do
    receive do
      {:sealed, %{"type" => "session.status"} = report} ->
        remember(report)
        if predicate.(report), do: report, else: await_status(predicate, timeout)

      {:sealed, _other} ->
        await_status(predicate, timeout)
    after
      timeout -> flunk("no matching session.status within #{timeout}ms")
    end
  end

  defp await_dormant(timeout \\ 15_000) do
    receive do
      {:sealed, %{"type" => "session.dormant"} = report} -> report
      {:sealed, _other} -> await_dormant(timeout)
    after
      timeout -> flunk("no session.dormant within #{timeout}ms")
    end
  end

  # Arrival times of every status report this test has seen, kept in the process
  # dictionary because the reports arrive in the mailbox and the question is about the
  # spacing between them.
  defp remember(_report) do
    now = System.monotonic_time(:millisecond)
    Process.put(:status_times, [now | Process.get(:status_times, [])])
  end

  defp status_gaps do
    :status_times
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
  end
end
