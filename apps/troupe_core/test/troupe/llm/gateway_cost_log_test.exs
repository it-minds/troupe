defmodule Troupe.LLM.GatewayCostLogTest do
  @moduledoc """
  What is said when a gateway's cost header and its stream name different costs for one
  call (#1133): the stream's is counted, and the difference is said once, at debug level.

  The suite logs at `critical`, and the level is the VM's, so it is lowered for each test
  and put back; the module runs alone for that.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Troupe.LLM.Gateway

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "where they differ the stream's wins, and the difference is said once at debug" do
    log =
      capture_log([level: :debug], fn ->
        assert %Gateway{cost_micros: 520} =
                 Gateway.with_reported_cost(%Gateway{request_id: "r1", cost_micros: 500}, 520)
      end)

    assert [_one] = Regex.scan(~r/cost header said 500 micros and its stream 520/, log)
    assert log =~ "[debug]"
  end

  test "the same figure in both, or a stream that said none, is said nothing of" do
    log =
      capture_log([level: :debug], fn ->
        assert %Gateway{cost_micros: 500} =
                 Gateway.with_reported_cost(%Gateway{cost_micros: 500}, 500)

        assert %Gateway{cost_micros: 500} =
                 Gateway.with_reported_cost(%Gateway{cost_micros: 500}, nil)
      end)

    refute log =~ "cost header"
  end
end
