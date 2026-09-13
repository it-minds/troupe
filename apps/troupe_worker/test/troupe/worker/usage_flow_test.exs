defmodule Troupe.Worker.UsageFlowTest do
  @moduledoc """
  A session runs, and what it cost reaches the plane.

  The whole path in one test: an agent finishes a turn, the log writes an `llm_response`
  carrying what the gateway charged, the collector picks it up without anybody sending a
  message, and a batch goes out naming the same request ids the gateway used. Then the
  two failure shapes that matter — the plane not being there, and the pod losing its
  table — and the claim that neither loses a charge.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Session.Summary
  alias Troupe.Worker.Usage

  @moduletag timeout: 180_000

  setup context do
    if context[:store] do
      test = self()

      collector =
        start_supervised!(
          {Usage,
           [
             send: fn session_id, records ->
               send(test, {:batch, session_id, records})
               {:ok, records |> Enum.map(& &1["seq"]) |> Enum.max(fn -> 0 end)}
             end,
             interval_ms: 60_000
           ]}
        )

      # What a pod's `runtime.exs` sets. Global, which is why every test in this app is
      # synchronous, and removed again so no other suite starts collecting.
      Application.put_env(:troupe_core, :usage_sink, Usage)
      on_exit(fn -> Application.delete_env(:troupe_core, :usage_sink) end)

      Map.put(context, :collector, collector)
    else
      context
    end
  end

  test "a turn becomes a ledger row with the gateway's id and cost", context do
    context = requires_tier(context)
    fake = scripted([{:text, "done"}])

    assert {:ok, _} = activate(context, fake: fake, prompt: "hello")
    await_responses(context.session_id, 1)

    session_id = context.session_id
    assert :ok = Usage.flush(context.collector, session_id)
    assert_receive {:batch, ^session_id, [record]}

    assert %{
             "gateway_request_id" => "fake_" <> _rest,
             "model" => "fake-model",
             "cost_micros" => cost,
             "input_tokens" => input
           } = record

    assert cost > 0
    assert input > 0

    # And the same numbers reached the session's own projection, which is what
    # `session.status` reports to the plane.
    assert Summary.snapshot(session_id)["cost_micros"] == cost
  end

  test "the collector holds what the plane refused, and nothing is charged twice", context do
    context = requires_tier(context)
    test = self()
    :ok = stop_supervised!(Usage)

    refusing =
      start_supervised!(
        {Usage,
         [
           send: fn session_id, records ->
             send(test, {:refused, session_id, length(records)})
             {:error, :not_connected}
           end,
           interval_ms: 60_000
         ]}
      )

    fake = scripted([{:tools, [{"list_files", %{}}]}, {:text, "done"}])
    assert {:ok, _} = activate(context, fake: fake, prompt: "look")
    await_responses(context.session_id, 2)

    session_id = context.session_id
    assert :ok = Usage.flush(refusing, session_id)
    assert_receive {:refused, ^session_id, 2}

    # Still held, because nothing acknowledged them.
    assert Usage.info(refusing).waiting == 2
  end

  test "a collector that lost its table folds the log again from the plane's watermark",
       context do
    context = requires_tier(context)
    fake = scripted([{:tools, [{"list_files", %{}}]}, {:text, "done"}])

    assert {:ok, _} = activate(context, fake: fake, prompt: "look")
    await_responses(context.session_id, 2)

    session_id = context.session_id

    # Everything the collector was holding, gone — a pod restart, or the cap.
    :ok = stop_supervised!(Usage)
    test = self()

    fresh =
      start_supervised!(
        {Usage,
         [
           send: fn id, records ->
             send(test, {:batch, id, records})
             {:ok, records |> Enum.map(& &1["seq"]) |> Enum.max(fn -> 0 end)}
           end,
           interval_ms: 60_000
         ]}
      )

    assert Usage.info(fresh).waiting == 0

    # The plane says it has nothing for this session, so the fold produces both turns.
    assert {:ok, folded} = Usage.follow(fresh, session_id, 0)
    assert folded == 2

    assert :ok = Usage.flush(fresh, session_id)
    assert_receive {:batch, ^session_id, records}
    assert length(records) == 2
    assert Enum.all?(records, &match?("fake_" <> _rest, &1["gateway_request_id"]))
  end

  test "a fold from a watermark past the last turn produces nothing", context do
    context = requires_tier(context)
    fake = scripted([{:text, "done"}])

    assert {:ok, _} = activate(context, fake: fake, prompt: "hello")
    await_responses(context.session_id, 1)

    head = Troupe.head_seq(context.session_id)
    assert {:ok, 0} = Usage.follow(context.collector, context.session_id, head)
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
end
