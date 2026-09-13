defmodule Troupe.Worker.UsageTest do
  @moduledoc """
  The table a pod keeps of what it owes the ledger, and the batch that pays it.

  Two properties are worth more than the rest: a record the plane acknowledged is
  forgotten, and a record it did not is kept. Everything else here is about what happens
  when the plane is not there — which, for a design whose whole claim is that losing this
  table costs nothing, is the interesting case.
  """

  use ExUnit.Case, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Session.Usage, as: Projection
  alias Troupe.Worker.Usage

  defp record(seq, cost \\ 100) do
    %{
      seq: seq,
      request_id: "gw_#{seq}",
      model: "m",
      input_tokens: 10,
      output_tokens: 2,
      cost_micros: cost,
      occurred_at: ~U[2026-09-13 10:00:00.000000Z]
    }
  end

  # A collector whose sending is a function this test controls, which is the only way to
  # test "the plane refused" without a plane. Under the default name, because the table
  # is named and there may only ever be one.
  defp collector(opts \\ []) do
    test = self()

    send_fn =
      Keyword.get(opts, :send, fn session_id, records ->
        send(test, {:batch, session_id, records})
        {:ok, records |> Enum.map(& &1["seq"]) |> Enum.max(fn -> 0 end)}
      end)

    start_supervised!({Usage,
     [
       send: send_fn,
       # Long enough that nothing ticks unless a test asks it to.
       interval_ms: Keyword.get(opts, :interval_ms, 60_000),
       batch: Keyword.get(opts, :batch, 500),
       max_rows: Keyword.get(opts, :max_rows, 20_000)
     ]})
  end

  describe "put/2" do
    test "writes from the caller's own process, without touching the collector" do
      pid = collector()

      task = Task.async(fn -> Usage.put("s-1", record(1)) end)
      assert Task.await(task) == :ok

      # The collector never saw a message; the row is simply there.
      assert {:messages, []} = Process.info(pid, :messages)
      assert Usage.info(pid).waiting == 1
    end

    test "with no collector running it is a no-op rather than a crash" do
      refute Process.whereis(Usage)
      assert Usage.put("s-1", record(1)) == :ok
    end

    test "the same sequence twice is one row, because the key is the sequence" do
      pid = collector()
      Usage.put("s-1", record(4))
      Usage.put("s-1", record(4, 999))
      assert Usage.info(pid).waiting == 1
    end
  end

  describe "flushing" do
    test "sends one batch per session and forgets what was acknowledged" do
      pid = collector()
      Usage.put("s-1", record(1))
      Usage.put("s-1", record(2))
      Usage.put("s-2", record(1))

      assert :ok = Usage.flush(pid, "s-1")
      assert_receive {:batch, "s-1", [%{"seq" => 1}, %{"seq" => 2}]}

      # s-1 is gone; s-2 was never asked for and is still waiting.
      assert Usage.info(pid).waiting == 1
      assert :ok = Usage.flush(pid, "s-2")
      assert Usage.info(pid).waiting == 0
    end

    test "a plane that refuses keeps every row for the next attempt" do
      test = self()

      pid =
        collector(
          send: fn session_id, records ->
            send(test, {:attempt, session_id, length(records)})
            {:error, :not_connected}
          end
        )

      Usage.put("s-1", record(1))
      Usage.put("s-1", record(2))

      assert :ok = Usage.flush(pid, "s-1")
      assert_receive {:attempt, "s-1", 2}
      assert Usage.info(pid).waiting == 2
    end

    test "a watermark behind what was sent keeps the rows above it" do
      # The plane recorded up to 1 and stopped — a record that fails to insert stops the
      # watermark there rather than letting the ones after it carry it past a gap.
      pid = collector(send: fn _session_id, _records -> {:ok, 1} end)

      Usage.put("s-1", record(1))
      Usage.put("s-1", record(2))
      Usage.put("s-1", record(3))

      assert :ok = Usage.flush(pid, "s-1")
      assert Usage.info(pid).waiting == 2
    end

    test "the interval drains without anyone asking" do
      pid = collector(interval_ms: 50)
      Usage.put("s-1", record(1))

      assert_receive {:batch, "s-1", [%{"seq" => 1}]}, 2_000
      assert Usage.info(pid).waiting == 0
    end
  end

  describe "the cap" do
    test "drops rather than grows, and says so" do
      pid = collector(max_rows: 4)

      for seq <- 1..10, do: Usage.put("s-1", record(seq))

      # Trimming happens where the collector is already doing work, so ask it to.
      {:ok, 0} = Usage.follow(pid, "no-such-session", 0)

      info = Usage.info(pid)
      assert info.waiting == 4
      assert info.dropped == 6
    end
  end

  describe "follow/3" do
    test "a session with no log process folds nothing and does not crash" do
      pid = collector()
      assert {:ok, 0} = Usage.follow(pid, "s-gone", 0)
    end

    test "folds a real log forward from the plane's watermark" do
      pid = collector()
      session_id = "s-fold-#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), session_id)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      start_supervised!({Log, session_id: session_id, workspace_root: dir, state_dir: dir})

      for n <- 1..3 do
        {:ok, _seq} =
          Log.append(session_id, ["root"], :llm_response, %{
            "usage" => %{"input_tokens" => 10, "output_tokens" => n},
            "gateway" => %{"request_id" => "gw_#{n}", "cost_micros" => n * 1000}
          })
      end

      # Everything at or below the watermark is already charged and must not come back.
      assert {:ok, 1} = Usage.follow(pid, session_id, 2)
      assert :ok = Usage.flush(pid, session_id)
      assert_receive {:batch, ^session_id, [%{"seq" => 3, "cost_micros" => 3000}]}
    end
  end

  test "a record put by the sink is the one the projection would have folded" do
    pid = collector()

    event = %Event{
      seq: 5,
      type: "llm_response",
      agent: ["root"],
      ts: "2026-09-13T10:00:05.000000Z",
      data: %{
        "usage" => %{"input_tokens" => 7, "output_tokens" => 3},
        "model" => "m",
        "gateway" => %{"request_id" => "gw_5", "cost_micros" => 42}
      }
    }

    :ok = Usage.put("s-1", Projection.record("s-1", event))
    assert :ok = Usage.flush(pid, "s-1")

    assert_receive {:batch, "s-1",
                    [%{"seq" => 5, "gateway_request_id" => "gw_5", "cost_micros" => 42}]}
  end
end
