defmodule Troupe.Agent.StoppedCallTest do
  @moduledoc """
  A model call the agent gives up on is stopped, and what it reported is counted (D69,
  Decision 788). Req's `receive_timeout` limits only the gap between packets, so a reply
  that keeps coming went on past `llm_timeout_ms`, generated and billed up to
  `max_tokens`, after the agent had moved on, and none of it was counted.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Test.EndlessStandIn

  @overflow {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

  describe "a call still streaming at llm_timeout_ms" do
    test "in a turn is stopped, and what it reported is counted for the turn", context do
      sid = run(context, steps: [{:endless, 100}], config_overrides: [llm_timeout_ms: 1_000])

      error = await_event(sid, :llm_error, 10_000)
      ended = await_event(sid, :turn_ended, 10_000)

      assert error.data["reason"] =~ "did not answer in time"
      assert eventually(fn -> streams(sid) == [] end), "the stream is still running"

      # What the stand-in reported before it was stopped, as `llm_response` says it.
      assert %{"model" => "fake-model", "usage" => usage} = error.data["stopped"]

      assert usage == %{
               "input_tokens" => 100,
               "output_tokens" => 1,
               "cache_read" => 0,
               "cache_write" => 0
             }

      assert %{"calls" => 1, "input_tokens" => 100, "output_tokens" => 1} = ended.data["turn"]
    end

    test "in a compaction is stopped, and what it reported is counted for the turn", context do
      steps =
        List.duplicate({:tools, [{"todo_read", %{}}]}, 4) ++
          [@overflow, {:endless, 100}, {:text, "done"}]

      sid = run(context, steps: steps, config_overrides: [llm_timeout_ms: 1_000])
      await_state(sid, [:compacting], 10_000)
      ended = await_event(sid, :turn_ended, 10_000)

      assert eventually(fn -> streams(sid) == [] end), "the summariser's stream is still running"
      assert events_of_type(sid, :compacted) == []

      # Five replies and the summary that was stopped, which had reported its prompt.
      assert %{"calls" => 6, "input_tokens" => 600} = ended.data["turn"]
    end

    test "that reported nothing is counted as a call nobody priced", context do
      sid =
        run(context,
          steps: [{:endless, 100, :no_usage}],
          config_overrides: [llm_timeout_ms: 1_000]
        )

      error = await_event(sid, :llm_error, 10_000)
      ended = await_event(sid, :turn_ended, 10_000)

      assert eventually(fn -> streams(sid) == [] end), "the stream is still running"
      assert error.data["stopped"] == %{"model" => "fake-model"}

      assert ended.data["turn"] == %{
               "calls" => 1,
               "input_tokens" => 0,
               "cache_read" => 0,
               "cache_write" => 0,
               "output_tokens" => 0,
               "cost_micros" => 0,
               "unpriced" => 1
             }
    end

    test "is read back by a restart as the turn counted it", context do
      sid = run(context, steps: [{:endless, 100}], config_overrides: [llm_timeout_ms: 1_000])
      await_event(sid, :turn_ended, 10_000)

      assert budget(sid).input_tokens == 100

      agent = Registry.agent_pid(sid, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
      await_event(sid, :agent_restarted)
      await_state(sid, [:idle])

      assert budget(sid).input_tokens == 100
    end
  end

  test "a cancel stops the call the same way, and counts what it reported", context do
    sid = run(context, steps: [{:endless, 100}])

    # The stand-in reports its usage before its first delta.
    await_event(sid, :llm_delta, 10_000)
    Troupe.cancel(sid)
    cancelled = await_event(sid, :cancelled, 10_000)

    assert eventually(fn -> streams(sid) == [] end), "the stream is still running"

    assert %{"model" => "fake-model", "usage" => %{"input_tokens" => 100}} =
             cancelled.data["stopped"]

    assert %{"calls" => 1, "input_tokens" => 100} = cancelled.data["turn"]
  end

  describe "over the wire, a call stopped at its timeout" do
    # The first request a test VM makes loads the HTTP client's modules, which from a slow
    # disk takes longer than the timeout these calls are given: done once here instead.
    setup do
      stand_in = EndlessStandIn.start()
      on_exit(fn -> EndlessStandIn.stop(stand_in) end)
      {:ok, %Req.Response{status: 404}} = Req.get(stand_in.base_url <> "/warm", retry: false)
      %{stand_in: stand_in}
    end

    test "closes its request, and Anthropic's message_start is counted", context do
      write_file(context, ".troupe/config.yaml", """
      version: 1
      models:
        prices:
          claude-sonnet-5: {input: 3, output: 15, cache_read: 0.3, cache_write: 3.75}
      """)

      sid =
        run(context,
          config_overrides: [
            provider: "anthropic",
            model: "claude-sonnet-5",
            base_url: context.stand_in.base_url,
            api_key: "test-key",
            llm_timeout_ms: 2_000
          ]
        )

      assert_receive {:endless_stand_in, :request, "/v1/messages"}, 5_000
      error = await_event(sid, :llm_error, 10_000)
      ended = await_event(sid, :turn_ended, 10_000)

      # Still producing when it was stopped: deltas were sent, and then the client went.
      assert_receive {:endless_stand_in, :closed, deltas}, 3_000
      assert deltas > 0

      assert error.data["stopped"]["usage"] ==
               %{
                 "input_tokens" => 2_000,
                 "cache_read" => 500,
                 "cache_write" => 0,
                 "output_tokens" => 1
               }

      # Priced as any call the gateway did not price: 2,000 at $3, 500 at $0.30 and one at
      # $15 a million.
      assert error.data["stopped"]["gateway"] == %{
               "cost_micros" => 6_165,
               "priced_locally" => true
             }

      assert %{"calls" => 1, "input_tokens" => 2_000, "cache_read" => 500, "cost_micros" => 6_165} =
               ended.data["turn"]
    end

    test "closes its request on an OpenAI-compatible provider, which reported nothing yet",
         context do
      sid =
        run(context,
          config_overrides: [
            provider: "openai",
            model: "gpt-test",
            base_url: context.stand_in.base_url,
            api_key: "test-key",
            llm_timeout_ms: 2_000
          ]
        )

      assert_receive {:endless_stand_in, :request, "/v1/chat/completions"}, 5_000
      error = await_event(sid, :llm_error, 10_000)
      ended = await_event(sid, :turn_ended, 10_000)

      assert_receive {:endless_stand_in, :closed, deltas}, 3_000
      assert deltas > 0

      assert error.data["stopped"] == %{"model" => "gpt-test"}
      assert %{"calls" => 1, "input_tokens" => 0, "unpriced" => 1} = ended.data["turn"]
    end
  end

  defp run(context, opts) do
    %{session: session} = start_session(context, opts)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    session.id
  end

  # The root agent's tasks: in a turn's model call, only the one streaming it.
  defp streams(sid), do: Task.Supervisor.children(Registry.tasks(sid, ["root"]))

  defp budget(sid) do
    {_name, state} = :sys.get_state(Registry.agent_pid(sid, ["root"]))
    state.budget
  end

  defp eventually(fun, timeout \\ 2_000),
    do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        poll(fun, deadline)
    end
  end
end
