defmodule Troupe.Bench do
  @moduledoc """
  `troupe bench`: the harness measured against budgets kept in the repository (issue #390,
  Decision 772).

  The offline suite (`Troupe.Bench.Scenarios`) runs each scenario against a scripted
  model (`Troupe.Bench.Model`), so it costs nothing, needs no network and gives the same
  numbers twice. What it measures is the harness's shape, not a model's answer: model
  calls per turn, what each prompt is made of and how it grows, where a tool result is
  cut, when compaction comes, what a cancel leaves running, whether the log is the
  session. Each measure is held to its budget in `priv/bench/budgets.json`, a maximum,
  and the run fails when one is exceeded or a check does not hold; moving a budget is a
  change to that file, reviewed like any other (`docs/developer/bench.md`).

  The report is one map, written as JSON (`json/1`) or as a Markdown table
  (`markdown/1`). Its shape is the one a run against a real model will fill too: an
  offline run leaves what it cannot know (times, cost, retries) `nil`, and the JSON of
  two offline runs of one build is the same, byte for byte.
  """

  alias Troupe.Bench.{Runner, Scenario, Scenarios}

  @schema 1

  @budgets_path Path.expand("../../priv/bench/budgets.json", __DIR__)
  @external_resource @budgets_path
  @budgets @budgets_path |> File.read!() |> Jason.decode!()

  @doc "The budgets the suite is held to: `%{scenario => %{measure => maximum}}`, from the file."
  @spec budgets() :: %{String.t() => %{String.t() => number()}}
  def budgets, do: @budgets

  @doc "The offline suite, in report order."
  @spec scenarios() :: [Scenario.t()]
  def scenarios, do: Scenarios.all()

  @doc """
  Run the offline suite and answer the report.

  Options: `:budgets` instead of the file's, and `:only`, the names of the scenarios to
  run. Each scenario runs in its own directories under a new temporary one, removed
  afterwards.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    budgets = Keyword.get(opts, :budgets, @budgets)
    only = Keyword.get(opts, :only)
    scenarios = Enum.filter(scenarios(), &(only == nil or &1.name in only))
    base = Path.join(System.tmp_dir!(), "troupe-bench-#{System.unique_integer([:positive])}")

    try do
      results =
        Enum.map(scenarios, &result(&1, Runner.run(&1, base), Map.get(budgets, &1.name, %{})))

      %{
        "schema" => @schema,
        "suite" => "troupe bench",
        "mode" => "offline",
        "version" => version(),
        "passed" => Enum.all?(results, & &1["passed"]),
        "scenarios" => results
      }
    after
      File.rm_rf(base)
    end
  end

  @doc "Whether every scenario passed."
  @spec passed?(map()) :: boolean()
  def passed?(report), do: report["passed"] == true

  defp result(%Scenario{} = scenario, run, budgets) do
    metrics = Enum.map(run.metrics, &metric(&1, budgets)) ++ unmeasured(run.metrics, budgets)

    checks =
      Enum.map(run.checks, fn {name, label, passed} ->
        %{"name" => name, "label" => label, "passed" => passed}
      end)

    outcome = outcome(scenario, run.record)

    %{
      "name" => scenario.name,
      "title" => scenario.title,
      "error" => run.error,
      "outcome" => outcome,
      "runs" => if(run.record, do: [run.record], else: []),
      "metrics" => metrics,
      "checks" => checks,
      "passed" =>
        run.error == nil and Enum.all?(metrics, & &1["passed"]) and
          Enum.all?(checks, & &1["passed"]) and
          (outcome == nil or outcome["passed"] == true)
    }
  end

  defp metric({name, label, unit, value}, budgets) do
    budget = Map.get(budgets, name)

    %{
      "name" => name,
      "label" => label,
      "unit" => unit,
      "value" => value,
      "budget" => budget,
      "passed" => budget == nil or value <= budget
    }
  end

  # A budget for something the scenario no longer measures fails, rather than holding
  # nothing to anything while it reads as a promise.
  defp unmeasured(metrics, budgets) do
    measured = MapSet.new(metrics, &elem(&1, 0))

    budgets
    |> Enum.reject(fn {name, _budget} -> MapSet.member?(measured, name) end)
    |> Enum.sort()
    |> Enum.map(fn {name, budget} ->
      %{
        "name" => name,
        "label" => "not measured",
        "unit" => nil,
        "value" => nil,
        "budget" => budget,
        "passed" => false
      }
    end)
  end

  defp outcome(%Scenario{outcome: nil}, _record), do: nil

  defp outcome(scenario, record) do
    %{
      "what" => Scenario.describe_outcome(scenario),
      "passed" => record != nil and record["outcome"] == true
    }
  end

  defp version, do: :troupe_core |> Application.spec(:vsn) |> to_string()

  # -- the two formats --------------------------------------------------------------

  @doc "The report as JSON, keys sorted, so two runs diff line by line."
  @spec json(map()) :: String.t()
  def json(report), do: Jason.encode!(report, pretty: true) <> "\n"

  @doc """
  The report as a Markdown table, a row a measure, then a line saying how it went: what
  `troupe bench` prints and CI puts in its summary.
  """
  @spec markdown(map()) :: String.t()
  def markdown(report) do
    rows = Enum.flat_map(report["scenarios"], &rows/1)
    failed = Enum.flat_map(report["scenarios"], &failures/1)

    table =
      ["| scenario | measure | value | budget | |", "| --- | --- | ---: | ---: | --- |"] ++
        Enum.map(rows, fn cells -> "| " <> Enum.join(cells, " | ") <> " |" end)

    Enum.join(table, "\n") <> "\n\n" <> verdict(report, failed) <> "\n"
  end

  defp rows(scenario) do
    name = scenario["name"]

    error =
      if scenario["error"],
        do: [[name, "did not run: " <> scenario["error"], "", "", "FAILED"]],
        else: []

    outcome =
      case scenario["outcome"] do
        nil ->
          []

        outcome ->
          [
            [
              name,
              "outcome: " <> outcome["what"],
              yes_no(outcome["passed"]),
              "",
              ok(outcome["passed"])
            ]
          ]
      end

    metrics =
      Enum.map(scenario["metrics"], fn metric ->
        [
          name,
          metric["label"],
          value(metric["value"], metric["unit"]),
          value(metric["budget"], nil),
          ok(metric["passed"])
        ]
      end)

    checks =
      Enum.map(
        scenario["checks"],
        &[name, &1["label"], yes_no(&1["passed"]), "", ok(&1["passed"])]
      )

    error ++ metrics ++ checks ++ outcome
  end

  # `scenario/measure` for each thing that failed, the scenario alone when it did not run.
  defp failures(%{"name" => name} = scenario) do
    error = if scenario["error"], do: [name], else: []
    failed = Enum.filter(scenario["metrics"] ++ scenario["checks"], &(&1["passed"] == false))

    outcome =
      if match?(%{"passed" => false}, scenario["outcome"]), do: [name <> "/outcome"], else: []

    error ++ Enum.map(failed, &(name <> "/" <> &1["name"])) ++ outcome
  end

  defp verdict(report, []) do
    "troupe bench #{report["version"]}, #{report["mode"]}: #{length(report["scenarios"])} scenarios, " <>
      "every measure within its budget."
  end

  defp verdict(report, failed) do
    "troupe bench #{report["version"]}, #{report["mode"]}: FAILED " <>
      Enum.join(failed, ", ") <> "."
  end

  defp value(nil, _unit), do: ""
  defp value(value, nil), do: to_string(value)
  defp value(value, unit) when unit in ["share"], do: to_string(value)
  defp value(value, unit), do: "#{value} #{unit}"

  defp yes_no(true), do: "yes"
  defp yes_no(_other), do: "no"

  defp ok(true), do: "ok"
  defp ok(_other), do: "FAILED"
end
