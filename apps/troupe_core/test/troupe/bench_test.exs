defmodule Troupe.BenchTest do
  @moduledoc """
  `troupe bench`'s offline suite (issue #390, Decision 772): it passes on this build's
  numbers, a measure past its budget fails it, and its report has one shape that two
  runs write identically.

  `async: false`: while a scenario runs, the bench points `TROUPE_CONFIG_HOME` and
  `TROUPE_STATE_HOME` at its own directories, which no other test may see.
  """

  use ExUnit.Case, async: false

  alias Troupe.Bench
  alias Troupe.Bench.Scenario

  # The whole suite once for the module; the tests read the one report.
  setup_all do
    %{report: Bench.run()}
  end

  test "the suite passes on this build's numbers", %{report: report} do
    assert Bench.passed?(report), Bench.markdown(report)

    assert Enum.map(report["scenarios"], & &1["name"]) ==
             ~w(tool_calls cut_output compaction cancel replay onboard_claude_code onboard_opencode onboard_cursor onboard_copilot memory_stale_anchor)

    # #248: the command whose file changed is marked, and recall says so (Decision 838).
    memory = scenario(report, "memory_stale_anchor")
    assert Enum.all?(memory["checks"], & &1["passed"]), inspect(memory["checks"])

    # #389's turn: thirty tool calls are thirty-one model calls, each resending the last.
    tool_calls = scenario(report, "tool_calls")
    assert value(tool_calls, "model_calls") == 31
    assert value(tool_calls, "largest_prompt_bytes") > value(tool_calls, "first_prompt_bytes")

    # Compaction came at the configured share of the window and not before it.
    compaction = scenario(report, "compaction")
    assert value(compaction, "fired_at_share") >= %Troupe.Config{}.compact_at
    assert value(compaction, "compactions") >= 1

    assert %{"what" => "hello.txt holds what was asked for", "passed" => true} =
             scenario(report, "replay")["outcome"]
  end

  test "every budget in the file holds a measure its scenario takes", %{report: report} do
    for {name, budgets} <- Bench.budgets(), {measure, budget} <- budgets do
      assert entry = scenario(report, name), "budgets.json names #{name}, which is not a scenario"
      assert %{"value" => value, "budget" => ^budget} = metric(entry, measure)
      assert is_number(value), "#{name}/#{measure} has a budget and is not measured"
    end
  end

  test "a measure past its budget fails the run, and the report says which" do
    budgets = put_in(Bench.budgets(), ["tool_calls", "model_calls"], 30)
    report = Bench.run(budgets: budgets, only: ["tool_calls"])

    refute Bench.passed?(report)

    assert %{"value" => 31, "budget" => 30, "passed" => false} =
             metric(scenario(report, "tool_calls"), "model_calls")

    assert Bench.markdown(report) =~
             "| tool_calls | model calls in the turn | 31 calls | 30 | FAILED |"

    assert Bench.markdown(report) =~ "FAILED tool_calls/model_calls."
  end

  test "a budget for a measure nobody takes fails rather than holding nothing" do
    report = Bench.run(budgets: %{"replay" => %{"seconds" => 1}}, only: ["replay"])

    refute Bench.passed?(report)
    assert %{"value" => nil, "passed" => false} = metric(scenario(report, "replay"), "seconds")
  end

  test "two runs write the same JSON, byte for byte", %{report: report} do
    assert Bench.json(Bench.run()) == Bench.json(report)
  end

  # The fields a run against a real model fills as well: an offline run leaves the times,
  # the cost and the retries empty, and nothing else.
  test "the report has schema 1's shape", %{report: report} do
    assert Map.keys(report) == ~w(mode passed scenarios schema suite version)
    assert %{"schema" => 1, "mode" => "offline", "suite" => "troupe bench"} = report

    for entry <- report["scenarios"] do
      assert Map.keys(entry) == ~w(checks error metrics name outcome passed runs title)
      assert [run] = entry["runs"]

      assert Map.keys(run) ==
               ~w(approvals cached_tokens calls compactions cost_micros input_tokens model model_calls outcome output_tokens retries stop_reason tools turns wall_ms)

      assert %{"wall_ms" => nil, "cost_micros" => nil, "retries" => nil} = run
      assert length(run["calls"]) == run["model_calls"]

      for call <- run["calls"] do
        assert Map.keys(call) ==
                 ~w(conversation_bytes first_token_ms input_tokens latency_ms output_tokens prompt_bytes summariser system_bytes tool_definition_bytes tool_result_bytes)
      end

      for tool <- run["tools"], do: assert(Map.keys(tool) == ~w(calls failures ms name))

      for metric <- entry["metrics"],
          do: assert(Map.keys(metric) == ~w(budget label name passed unit value))

      for check <- entry["checks"], do: assert(Map.keys(check) == ~w(label name passed))
    end

    assert {:ok, _decoded} = Jason.decode(Bench.json(report))
  end

  @tag :tmp_dir
  test "an outcome is a file's content, or a command that exits 0", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "x\n")
    scenario = %Scenario{name: "s", title: "s", prompt: "p", measure: fn _ctx -> {[], []} end}

    assert Scenario.outcome(scenario, dir) == nil
    assert Scenario.outcome(%{scenario | outcome: {:file, "a.txt", "x\n"}}, dir) == true
    assert Scenario.outcome(%{scenario | outcome: {:file, "a.txt", "y\n"}}, dir) == false
    assert Scenario.outcome(%{scenario | outcome: {:file, "b.txt", "x\n"}}, dir) == false

    assert Scenario.outcome(
             %{scenario | outcome: {:command, ["elixir", "-e", "System.halt(0)"]}},
             dir
           ) == true

    assert Scenario.outcome(
             %{scenario | outcome: {:command, ["elixir", "-e", "System.halt(3)"]}},
             dir
           ) == false
  end

  defp scenario(report, name), do: Enum.find(report["scenarios"], &(&1["name"] == name))
  defp metric(scenario, name), do: Enum.find(scenario["metrics"], &(&1["name"] == name))
  defp value(scenario, name), do: metric(scenario, name)["value"]
end
