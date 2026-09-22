defmodule Troupe.LLM.GatewayTest do
  @moduledoc """
  Reading what the gateway said about a call it billed.

  The numbers here become money in a ledger, so the parsing is integer arithmetic over
  the digits rather than a float, and the tests that matter are the ones about a value
  that a float would get very slightly wrong.
  """

  use ExUnit.Case, async: true

  alias Troupe.LLM.Gateway

  describe "from_headers/1" do
    test "reads LiteLLM's call id and cost" do
      headers = %{
        "x-litellm-call-id" => ["7f2b1c90-0a44-4f11-9d1f-6b5e2c0a9a11"],
        "x-litellm-response-cost" => ["0.018400"],
        "content-type" => ["text/event-stream"]
      }

      assert %Gateway{request_id: "7f2b1c90-0a44-4f11-9d1f-6b5e2c0a9a11", cost_micros: 18_400} =
               Gateway.from_headers(headers)
    end

    test "falls back to the generic request id, which is what other gateways send" do
      assert %Gateway{request_id: "req_1", cost_micros: nil} =
               Gateway.from_headers(%{"x-request-id" => ["req_1"]})
    end

    test "prefers the specific id over the generic one" do
      headers = %{"x-request-id" => ["generic"], "x-litellm-call-id" => ["specific"]}
      assert %Gateway{request_id: "specific"} = Gateway.from_headers(headers)
    end

    test "a gateway that says nothing leaves both empty, which is a fact and not an error" do
      assert %Gateway{request_id: nil, cost_micros: nil} = Gateway.from_headers(%{})
    end

    test "takes a list of pairs, which is what a hand-written caller passes" do
      pairs = [{"X-LiteLLM-Call-Id", "abc"}, {"x-litellm-response-cost", "1.5"}]
      assert %Gateway{request_id: "abc", cost_micros: 1_500_000} = Gateway.from_headers(pairs)
    end
  end

  describe "to_micros/1" do
    test "an amount a float would round wrongly is exact" do
      # 0.07 * 1_000_000 is 70000.00000000001 in binary floating point, and
      # `round/1` happens to save that one. 8.87 does not: 8.87 * 1_000_000 is
      # 8869999.999999999, and a ledger that lost a unit per call would drift.
      assert Gateway.to_micros("8.87") == 8_870_000
      assert Gateway.to_micros("0.07") == 70_000
      assert Gateway.to_micros("0.000001") == 1
    end

    test "more precision than a micro-unit can hold is truncated, not rounded up" do
      assert Gateway.to_micros("0.0000009") == 0
      assert Gateway.to_micros("1.2345678") == 1_234_567
    end

    test "a whole number, a leading dot and a trailing dot all parse" do
      assert Gateway.to_micros("3") == 3_000_000
      assert Gateway.to_micros("0.5") == 500_000
      assert Gateway.to_micros("2.") == 2_000_000
    end

    # What a real LiteLLM sends for a cheap call: `x-litellm-response-cost:
    # 1.0500000000000001e-05`. The digit arithmetic read that as nil, so every session
    # on that gateway showed a cost of zero.
    test "scientific notation, which is how a small cost arrives" do
      assert Gateway.to_micros("1.0500000000000001e-05") == 10
      assert Gateway.to_micros("1.05e-05") == 10
      assert Gateway.to_micros("9e-07") == 0
      assert Gateway.to_micros("5E-01") == 500_000
      assert Gateway.to_micros("1.5e2") == 150_000_000
      assert Gateway.to_micros("2e+1") == 20_000_000
      assert Gateway.to_micros("-1.5e-3") == 0
    end

    test "nothing sensible is nothing rather than zero" do
      assert Gateway.to_micros("1e") == nil
      assert Gateway.to_micros("1e1.5") == nil
      assert Gateway.to_micros("e-05") == nil
      assert Gateway.to_micros(nil) == nil
      assert Gateway.to_micros("free") == nil
      assert Gateway.to_micros("1.2.3") == nil
      assert Gateway.to_micros("") == nil
    end

    test "a negative amount is floored at zero rather than credited" do
      assert Gateway.to_micros("-0.5") == 0
      assert Gateway.to_micros("-2.25") == 0
    end
  end
end
