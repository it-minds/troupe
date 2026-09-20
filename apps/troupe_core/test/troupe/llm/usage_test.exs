defmodule Troupe.LLM.UsageTest do
  @moduledoc "Four disjoint figures, and what the budget counts of them (Decision 657)."

  use ExUnit.Case, async: true

  alias Troupe.Budget
  alias Troupe.LLM.Usage

  test "billed input is fresh tokens and cache writes; total input is the prompt's length" do
    usage = %Usage{input_tokens: 300, cache_read: 140_000, cache_write: 5_000, output_tokens: 20}

    assert Usage.billed_input(usage) == 5_300
    assert Usage.total_input(usage) == 145_300

    assert Usage.add(usage, usage) ==
             %Usage{input_tokens: 600, cache_read: 280_000, cache_write: 10_000, output_tokens: 40}
  end

  test "the budget charges what was billed, not what the cache served" do
    budget = %Budget{max_input_tokens: 10_000}
    warm = %Usage{input_tokens: 300, cache_read: 140_000, cache_write: 5_000, output_tokens: 20}

    charged = Budget.charge_usage(budget, warm)
    assert charged.input_tokens == 5_300
    assert charged.output_tokens == 20
    assert Budget.check(charged) == :ok, "a prompt served from cache is not the budget's to stop"

    # What a child reports back is already the billed figure, so a parent counts nothing twice.
    assert Budget.usage(charged) == %Usage{input_tokens: 5_300, output_tokens: 20}
    assert Budget.charge_usage(budget, Budget.usage(charged)).input_tokens == 5_300
  end

  test "round-trips through the log, and an older event folds as an uncached prompt" do
    usage = %Usage{input_tokens: 12, output_tokens: 40, cache_read: 180_000, cache_write: 2_000}

    assert usage |> Usage.to_json() |> Usage.from_json() == usage

    assert Usage.from_json(%{"input_tokens" => 10, "output_tokens" => 2}) ==
             %Usage{input_tokens: 10, output_tokens: 2}

    assert Usage.from_json(nil) == %Usage{}
    assert Usage.from_json(%{"input_tokens" => "many"}) == %Usage{}
  end
end
