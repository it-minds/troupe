defmodule Troupe.LLM.ProviderErrorsTest do
  @moduledoc "What a provider failure was, in a word the agent can act on and a sentence a person can (Decision 659)."

  use ExUnit.Case, async: true

  alias Troupe.LLM.Provider

  test "a 400 naming a context error is an overflow; every other 400 is not" do
    assert {:context_overflow, _} = Provider.classify({:http_status, 400, "prompt is too long: 250000 tokens"})

    assert {:context_overflow, _} =
             Provider.classify({:http_status, 400, "This model's maximum context length is 128000"})

    assert {:http_status, 400, _} = Provider.classify({:http_status, 400, "invalid_request: bad tool schema"})
  end

  test "auth, unknown model and rate limits are told apart" do
    assert {:auth, _} = Provider.classify({:http_status, 401, "invalid x-api-key"})
    assert {:auth, _} = Provider.classify({:http_status, 403, "forbidden"})
    assert {:model_not_found, _} = Provider.classify({:http_status, 404, "model: not_a_model"})
    assert {:rate_limited, _} = Provider.classify({:retries_exhausted, {:http_status, 429}})
  end

  test "describe_error says what happened in words a person can act on" do
    assert Provider.describe_error({:http_status, 404, "no such model"}) =~ "does not know that model"
    assert Provider.describe_error({:http_status, 401, ""}) == "the provider rejected the credentials"
    assert Provider.describe_error({:http_status, 400, "prompt is too long"}) =~ "no longer fits"
    assert Provider.describe_error({:retries_exhausted, {:http_status, 503}}) =~ "gave up after retrying"
    assert Provider.describe_error(:missing_api_key) =~ "no API key"
    assert Provider.describe_error({:timeout, 300_000}) =~ "did not answer in time"
    assert Provider.describe_error({:api_error, "overloaded"}) == "the provider reported an error (overloaded)"
  end

  test "retry-after is read in seconds, from Req's headers or a list of pairs" do
    assert Provider.retry_after_ms(%{"retry-after" => ["30"]}) == 30_000
    assert Provider.retry_after_ms([{"Retry-After", "2"}]) == 2_000
    assert Provider.retry_after_ms(%{}) == nil
    assert Provider.retry_after_ms(%{"retry-after" => ["Wed, 21 Oct 2026 07:28:00 GMT"]}) == nil
    assert Provider.retry_after_ms(%{"retry-after" => ["0"]}) == nil
  end

  test "a rate limit gets more attempts than the budget says, and waits what it was told" do
    counter = :counters.new(1, [:atomics])

    limited = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) <= 3, do: {:retry, {:http_status, 429}, 1}, else: {:ok, :answered}
    end

    assert {:ok, :answered} = Provider.with_retries(limited, 0)
    assert :counters.get(counter, 1) == 4

    # A 5xx keeps the ordinary budget.
    assert {:error, {:retries_exhausted, {:http_status, 503}}} =
             Provider.with_retries(fn -> {:retry, {:http_status, 503}} end, 0)
  end
end
