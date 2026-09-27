defmodule Troupe.Agent.BudgetAnswerTest do
  @moduledoc """
  What the budget question offers and what an answer to it means (Decision 699, issue
  #183): sizes anchored on what was used, every offered label reading back as the
  decision it names, a typed amount in any spelling meaning that much more of the limit
  that asked, nonsense answered with a reason rather than read as a stop, the terms a
  ceiling on a pod, and the words a person reads — the safety net, the money, the cost
  of the raise on offer.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.BudgetQuestion

  defp entry(used, limit), do: %{used: used, limit: limit, fraction: used / limit}

  defp ctx(limit \\ :max_turns, used \\ 40, opts \\ []) do
    BudgetQuestion.context(limit, entry(used, used), [path: "/w/.troupe/config.yaml"] ++ opts)
  end

  defp parse(text, ctx), do: BudgetQuestion.parse(text, ctx)
  defp labels(ctx), do: Enum.map(BudgetQuestion.options(ctx), & &1.label)

  describe "the steps" do
    test "are three round numbers from a quarter of what was used, never below the smallest" do
      assert BudgetQuestion.steps(:max_turns, 40) == [10, 25, 50]
      assert BudgetQuestion.steps(:max_turns, 2) == [5, 10, 25]
      assert BudgetQuestion.steps(:max_turns, 0) == [5, 10, 25]
      assert BudgetQuestion.steps(:max_turns, 1_000_000) == [1_000, 2_500, 5_000]
      assert BudgetQuestion.steps(:max_input_tokens, 2_000_000) == [500_000, 1_000_000, 2_500_000]
      assert BudgetQuestion.steps(:max_output_tokens, 150) == [10_000, 25_000, 50_000]

      assert BudgetQuestion.steps(:wall_clock, 30 * 60_000) == [
               10 * 60_000,
               15 * 60_000,
               30 * 60_000
             ]
    end
  end

  describe "the options" do
    test "offer the run, the session, no limit, the workspace and stop, and every label reads back" do
      ctx = ctx()

      assert labels(ctx) == [
               "+10 turns this run",
               "+25 turns this run",
               "+50 turns this run",
               "+25 turns this session",
               "+50 turns this session",
               "no limit this session",
               "+50 turns this workspace",
               "stop"
             ]

      assert parse("+10 turns this run", ctx) == {:ok, {:extend, :run, 10}}
      assert parse("+25 turns this session", ctx) == {:ok, {:extend, :session, 25}}
      assert parse("no limit this session", ctx) == {:ok, :always}
      assert parse("+50 turns this workspace", ctx) == {:ok, {:extend, :workspace, 50}}
      assert parse("stop", ctx) == {:ok, :deny}

      workspace =
        Enum.find(BudgetQuestion.options(ctx), &(&1.label == "+50 turns this workspace"))

      assert workspace.description =~ "max_turns: 90 written to /w/.troupe/config.yaml"
    end

    test "say the run is an iteration inside a loop" do
      assert "+10 turns this iteration" in labels(ctx(:max_turns, 40, run_word: "iteration"))
      assert parse("+10 iteration", ctx()) == {:ok, {:extend, :run, 10}}
    end

    test "price each step at the session's rate" do
      # $1.20 over 40 turns is three cents a turn.
      ctx = ctx(:max_turns, 40, spent_micros: 1_200_000)
      [ten | _] = BudgetQuestion.options(ctx)
      assert ten.description =~ "(roughly $0.30)"

      # A fraction of a cent is said as such rather than rounded to nothing.
      [five | _] = BudgetQuestion.options(ctx(:max_turns, 2, spent_micros: 600))
      assert five.description =~ "(under a cent)"

      assert Enum.find(BudgetQuestion.options(ctx), &(&1.label == "+25 turns this session")).description =~
               "$0.75"
    end
  end

  describe "a typed amount" do
    test "in every spelling means that much more of the limit that asked, for the session unless said" do
      ctx = ctx()

      for text <- [
            "50",
            "+50",
            "50 turns",
            "+50 turns",
            " +50 TURNS ",
            "50 this session",
            "+50 for this session"
          ] do
        assert parse(text, ctx) == {:ok, {:extend, :session, 50}}, text
      end

      assert parse("+50 run", ctx) == {:ok, {:extend, :run, 50}}
      assert parse("50 turns this run", ctx) == {:ok, {:extend, :run, 50}}
      assert parse("+25 workspace", ctx) == {:ok, {:extend, :workspace, 25}}
      assert parse("25 for this repo from now on", ctx) == {:ok, {:extend, :workspace, 25}}
    end

    test "on tokens takes k, m and a bare count, and refuses one that would not last a call" do
      ctx = ctx(:max_input_tokens, 150_000)

      assert parse("+50k tokens", ctx) == {:ok, {:extend, :session, 50_000}}
      assert parse("50k", ctx) == {:ok, {:extend, :session, 50_000}}
      assert parse("0.5m", ctx) == {:ok, {:extend, :session, 500_000}}
      assert parse("+2 million tokens this run", ctx) == {:ok, {:extend, :run, 2_000_000}}
      assert parse("50000", ctx) == {:ok, {:extend, :session, 50_000}}
      assert {:error, note} = parse("50", ctx)
      assert note =~ "would not last one call"
    end

    test "on time takes minutes by default, hours and seconds by name" do
      ctx = ctx(:wall_clock, 30 * 60_000)

      assert parse("+15 min", ctx) == {:ok, {:extend, :session, 15 * 60_000}}
      assert parse("15", ctx) == {:ok, {:extend, :session, 15 * 60_000}}
      assert parse("1 h", ctx) == {:ok, {:extend, :session, 60 * 60_000}}
      assert parse("+1.5 hours this run", ctx) == {:ok, {:extend, :run, 90 * 60_000}}
      assert parse("+90 s", ctx) == {:ok, {:extend, :session, 90_000}}
      assert parse("0.5", ctx) == {:ok, {:extend, :session, 30_000}}
    end

    test "in the wrong unit, or with a fraction of a turn, is asked back" do
      assert {:error, note} = parse("+50k tokens", ctx())
      assert note =~ "about turns"
      assert {:error, note} = parse("2.5 turns", ctx())
      assert note =~ "whole"
      assert {:error, note} = parse("+15 min", ctx(:max_input_tokens, 150_000))
      assert note =~ "about tokens"
    end
  end

  describe "the old answers" do
    test "keep their meaning" do
      ctx = ctx()

      for text <- ["allow", "yes", "y", "continue", "more"],
          do: assert(parse(text, ctx) == {:ok, :allow}, text)

      for text <- ["always", "a", "no limit", "unlimited"],
          do: assert(parse(text, ctx) == {:ok, :always}, text)

      for text <- ["deny", "no", "n", "stop", "Stop"],
          do: assert(parse(text, ctx) == {:ok, :deny}, text)
    end
  end

  describe "nonsense" do
    test "is answered with a reason, never read as a stop" do
      ctx = ctx()

      for text <- ["banana", "", "+", "50 bananas", "+25 this planet"] do
        assert {:error, note} = parse(text, ctx)
        assert note =~ "+25", text
      end
    end
  end

  describe "on a pod" do
    test "a limit the terms set cannot be raised past them, and the question says so" do
      ctx = ctx(:max_turns, 40, scopes: [:run, :session], cap: 40)

      assert labels(ctx) == ["stop"]

      assert BudgetQuestion.question(ctx) =~
               "runs under its team's terms, which set the turn limit at 40 turns"

      assert {:error, note} = parse("+50", ctx)
      assert note =~ "the team's terms cap the turn limit at 40 turns"
      assert {:error, _note} = parse("no limit", ctx)
    end

    test "a raise is offered only inside the terms' ceiling" do
      ctx = ctx(:max_turns, 40, scopes: [:run, :session], cap: 60)

      assert labels(ctx) == ["+10 turns this run", "stop"]
      assert BudgetQuestion.question(ctx) =~ "cap the turn limit at 60 turns"
      assert parse("+20", ctx) == {:ok, {:extend, :session, 20}}
      assert {:error, _note} = parse("+21", ctx)
    end

    test "the workspace is not a scope, and the question says why" do
      ctx = ctx(:max_input_tokens, 150_000, scopes: [:run, :session])

      refute Enum.any?(labels(ctx), &String.contains?(&1, "workspace"))
      assert BudgetQuestion.question(ctx) =~ "On a pod a raise lasts this run or this session"
      assert {:error, note} = parse("+50k workspace", ctx)
      assert note =~ "on a pod"
      assert parse("+50k", ctx) == {:ok, {:extend, :session, 50_000}}
    end
  end

  describe "the question" do
    test "says what the limit is for, what was used and spent, and what the middle step would cost" do
      text = BudgetQuestion.question(ctx(:max_turns, 40, spent_micros: 1_200_000))

      assert text =~
               "turns 40/40 (100%): the turn limit is a safety net against runaway loops and runaway spend."

      assert text =~
               "This session has used 40 turns and $1.20 so far; 25 turns more would cost roughly $0.75"

      assert text =~ "type an amount (+25, +25 session, +25 workspace)"
      assert text =~ "it asks again when that runs out"
    end

    test "says when nothing priced the calls, and puts the reason an answer was not read first" do
      assert BudgetQuestion.question(ctx()) =~ "used 40 turns so far; its calls carry no price"

      assert BudgetQuestion.question(ctx(), "`banana` is not an amount.") =~
               ~r/^`banana` is not an amount\. turns 40\/40/
    end

    test "reads amounts and money the way a person does" do
      assert BudgetQuestion.amount(:max_turns, 1) == "1 turn"
      assert BudgetQuestion.amount(:max_input_tokens, 50_000) == "50k tokens"
      assert BudgetQuestion.amount(:max_output_tokens, 2_500_000) == "2.5M tokens"
      assert BudgetQuestion.amount(:max_output_tokens, 150) == "150 tokens"
      assert BudgetQuestion.amount(:wall_clock, 15 * 60_000) == "15 min"
      assert BudgetQuestion.amount(:wall_clock, 90 * 60_000) == "1.5 h"
      assert BudgetQuestion.amount(:wall_clock, 45_000) == "45 s"
      assert BudgetQuestion.money(0) == "$0.00"
      assert BudgetQuestion.money(5_000) == "under a cent"
      assert BudgetQuestion.money(1_200_000) == "$1.20"
    end
  end
end
