defmodule Troupe.Session.UsageTest do
  @moduledoc """
  Turning a log into ledger rows.

  The property that everything downstream rests on: the same events produce the same
  rows, every time, on any pod, so re-folding after an outage is not a second charge.
  """

  # Not async: `observe/2` reads the sink out of application environment, which is
  # global, and a sink left in place while another session's log was being written would
  # deliver that session's records here.
  use ExUnit.Case, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Session.Usage

  defp event(seq, data, type \\ "llm_response") do
    %Event{
      seq: seq,
      type: type,
      agent: ["root"],
      ts: "2026-09-13T10:00:0#{rem(seq, 10)}.000000Z",
      data: data
    }
  end

  defp metered(seq, cost) do
    event(seq, %{
      "usage" => %{"input_tokens" => 100, "output_tokens" => 20},
      "model" => "anthropic/claude-opus-5",
      "gateway" => %{"request_id" => "gw_#{seq}", "cost_micros" => cost}
    })
  end

  test "one metered response becomes one row, with the gateway's own id" do
    assert [row] = Usage.records("s-1", [metered(4, 18_400)])

    assert %{
             seq: 4,
             request_id: "gw_4",
             model: "anthropic/claude-opus-5",
             input_tokens: 100,
             output_tokens: 20,
             cost_micros: 18_400
           } = row

    assert row.occurred_at == ~U[2026-09-13 10:00:04.000000Z]
  end

  test "everything that is not an llm_response is ignored, so a whole replay may be passed" do
    events = [
      event(1, %{"profile" => "build"}, "agent_started"),
      metered(2, 10),
      event(3, %{"name" => "read_file"}, "tool_call_started")
    ]

    assert [%{seq: 2}] = Usage.records("s-1", events)
  end

  test "rows come back in sequence order however the events arrived" do
    assert [%{seq: 2}, %{seq: 5}, %{seq: 9}] =
             Usage.records("s-1", [metered(9, 1), metered(2, 1), metered(5, 1)])
  end

  describe "a log written before there was a gateway to ask" do
    test "still records its tokens, with no cost and a synthesised id" do
      old = event(7, %{"usage" => %{"input_tokens" => 10, "output_tokens" => 2}})

      assert [%{seq: 7, input_tokens: 10, output_tokens: 2, cost_micros: 0} = row] =
               Usage.records("s-1", [old])

      assert row.request_id == "seq:s-1:7"
      assert row.model == nil
    end

    test "the synthesised id is stable, so re-folding is a duplicate rather than a charge" do
      old = event(7, %{"usage" => %{"input_tokens" => 10, "output_tokens" => 2}})
      assert Usage.records("s-1", [old]) == Usage.records("s-1", [old])
      assert Usage.synthetic_request_id("s-1", 7) == "seq:s-1:7"
    end

    test "two sessions at the same sequence do not collide" do
      old = event(7, %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}})
      [a] = Usage.records("s-1", [old])
      [b] = Usage.records("s-2", [old])
      assert a.request_id != b.request_id
    end
  end

  describe "malformed events" do
    test "missing or nonsense counts read as zero rather than crashing a flush" do
      assert [%{input_tokens: 0, output_tokens: 0, cost_micros: 0}] =
               Usage.records("s-1", [event(1, %{})])

      assert [%{input_tokens: 0, cost_micros: 0}] =
               Usage.records("s-1", [
                 event(2, %{
                   "usage" => %{"input_tokens" => "lots"},
                   "gateway" => %{"cost_micros" => -5}
                 })
               ])
    end

    test "an unparseable timestamp is no timestamp, and the plane dates it on arrival" do
      assert [%{occurred_at: nil}] =
               Usage.records("s-1", [%{event(1, %{}) | ts: "not a date"}])
    end
  end

  test "the wire shape names the gateway's id, because that is what the ledger joins on" do
    [row] = Usage.records("s-1", [metered(3, 500)])

    assert Usage.to_json(row) == %{
             "seq" => 3,
             "gateway_request_id" => "gw_3",
             "model" => "anthropic/claude-opus-5",
             "input_tokens" => 100,
             "output_tokens" => 20,
             "cost_micros" => 500,
             "occurred_at" => "2026-09-13T10:00:03.000000Z"
           }
  end

  describe "observe/2" do
    test "hands an llm_response to the configured sink and nothing else to anyone" do
      test = self()

      Application.put_env(:troupe_core, :usage_sink, __MODULE__.Sink)
      Application.put_env(:troupe_core, :usage_sink_test, test)
      on_exit(fn -> Application.delete_env(:troupe_core, :usage_sink) end)

      assert :ok = Usage.observe("s-1", metered(2, 7))
      assert_receive {:usage, "s-1", %{seq: 2, cost_micros: 7}}

      assert :ok = Usage.observe("s-1", event(3, %{}, "tool_call_started"))
      refute_receive {:usage, _session, _record}, 50
    end

    test "with no sink configured it does nothing at all, which is every laptop" do
      Application.delete_env(:troupe_core, :usage_sink)
      assert :ok = Usage.observe("s-1", metered(2, 7))
    end
  end

  defmodule Sink do
    @moduledoc false
    @behaviour Troupe.Session.Usage.Sink

    @impl true
    def put(session_id, usage) do
      send(Application.get_env(:troupe_core, :usage_sink_test), {:usage, session_id, usage})
      :ok
    end
  end
end
