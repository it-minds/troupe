defmodule Troupe.BudgetTest do
  @moduledoc """
  A lifted limit is lifted alone, and a delegate's turns are not a share of what its
  parent has left (Decision 687, issue #118).
  """

  use ExUnit.Case, async: true

  alias Troupe.Budget

  # Every limit spent at once, on a clock that started an hour ago.
  defp spent do
    %Budget{
      max_turns: 2,
      turns: 2,
      max_input_tokens: 100,
      input_tokens: 100,
      max_output_tokens: 10,
      output_tokens: 10,
      wall_clock_ms: 1_000,
      started_at: System.monotonic_time(:millisecond) - 3_600_000
    }
  end

  @limits [:max_turns, :max_input_tokens, :max_output_tokens, :wall_clock]

  for limit <- @limits do
    test "lifting #{limit} leaves the other three in force" do
      lifted = Budget.lift(spent(), unquote(limit))

      assert {:exhausted, other} = Budget.check(lifted)
      assert other != unquote(limit)

      rest = List.delete(@limits, unquote(limit))

      stopped_by =
        Enum.reduce_while(rest, {lifted, []}, fn _, {budget, seen} ->
          case Budget.check(budget) do
            {:exhausted, next} -> {:cont, {Budget.lift(budget, next), [next | seen]}}
            :ok -> {:halt, {budget, seen}}
          end
        end)
        |> elem(1)
        |> Enum.reverse()

      assert stopped_by == rest, "each of the others still stops the agent, in the usual order"
      assert Budget.check(Budget.lift(lifted, unquote(limit))) == {:exhausted, hd(rest)}, "lifting twice is once"
    end
  end

  test "a budget with every limit lifted never stops" do
    assert Budget.check(Enum.reduce(@limits, spent(), &Budget.lift(&2, &1))) == :ok
  end

  describe "a delegate's slice" do
    test "gets the turns its parent was first given, however many the parent has used" do
      parent = %Budget{max_turns: 40, turns: 33}
      assert Budget.slice(parent, 0.4).max_turns == 40
    end

    test "still takes tokens and time as a share of what the parent has left" do
      parent =
        Budget.start(%Budget{
          max_input_tokens: 1_000,
          input_tokens: 500,
          max_output_tokens: 100,
          output_tokens: 50,
          wall_clock_ms: 60_000
        })

      slice = Budget.slice(parent, 0.4)
      assert slice.max_input_tokens == 200
      assert slice.max_output_tokens == 20
      assert slice.wall_clock_ms <= 24_000
    end

    test "after a grant, the turns of the first allowance and not of the grants" do
      parent = %Budget{max_turns: 10, turns: 10} |> Budget.grant()
      assert parent.max_turns == 20
      assert Budget.slice(parent, 0.5).max_turns == 10
    end

    test "carries a lifted limit, sized from the parent's first allowance rather than its nothing left" do
      parent = %Budget{max_input_tokens: 1_000, input_tokens: 5_000} |> Budget.lift(:max_input_tokens)
      slice = Budget.slice(parent, 0.4)

      assert slice.lifted == [:max_input_tokens]
      assert slice.max_input_tokens == 400
      assert Budget.check(%{slice | input_tokens: 10_000}) == :ok
    end
  end
end
