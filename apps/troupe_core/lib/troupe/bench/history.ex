defmodule Troupe.Bench.History do
  @moduledoc """
  The live bench's history (Decision 773): `<state>/bench/results.jsonl`, one line a run,
  appended as each run ends, and what `troupe bench --compare` reads.

  A line is the run's record (schema 1's, Decision 772) with what places it: `schema`,
  `bench` (when the bench it was part of started, which groups a bench's runs), `version`,
  `scenario` and `run`, its number in the bench; the record already says the model. So
  "did this version get dearer than the last on the same model" is a question the file
  can answer, and so is "which of two models is cheaper per success".

  It is the person's own file, in their state directory beside their sessions, and holds
  nothing secret: what a run cost and did, never what it was sent.
  """

  alias Troupe.Bench.Live

  @doc "The history's file under a state directory, the platform's when `nil`."
  @spec path(Path.t() | nil) :: Path.t()
  def path(state_dir \\ nil),
    do: Path.join([Troupe.Paths.state_dir(state_dir), "bench", "results.jsonl"])

  @doc "Add one line. A `nil` path keeps nothing."
  @spec append(Path.t() | nil, map()) :: :ok
  def append(nil, _line), do: :ok

  def append(path, line) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(line) <> "\n", [:append])
  end

  @doc "Every line that reads as one, oldest first; a missing file is an empty history."
  @spec read(Path.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.flat_map(&run/1)
      {:error, _reason} -> []
    end
  end

  defp run(line) do
    case Jason.decode(line) do
      {:ok, %{"bench" => _, "scenario" => _} = run} -> [run]
      _other -> []
    end
  end

  @doc """
  The last bench against what came before it, as a Markdown table: for each scenario it
  ran, its runs against that scenario's last runs in an earlier bench, or, with `ref`, in
  the last earlier bench whose version or model is `ref`.
  """
  @spec compare(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def compare(path, ref \\ nil) do
    runs = read(path)

    case runs |> Enum.map(& &1["bench"]) |> Enum.uniq() |> List.last() do
      nil ->
        {:error, "no live bench is recorded in #{path} yet: `troupe bench --live` records one"}

      latest ->
        {now, earlier} = Enum.split_with(runs, &(&1["bench"] == latest))

        earlier =
          if ref,
            do: Enum.filter(earlier, &(&1["version"] == ref or &1["model"] == ref)),
            else: earlier

        {:ok, table(now, earlier, ref)}
    end
  end

  defp table(now, earlier, ref) do
    scenarios = now |> Enum.map(& &1["scenario"]) |> Enum.uniq()

    rows =
      Enum.flat_map(scenarios, fn scenario ->
        mine = Enum.filter(now, &(&1["scenario"] == scenario))
        rows(scenario, before(earlier, scenario), mine)
      end)

    [first | _] = now

    rows = rows ++ overall(scenarios, now, earlier)

    header = [
      "| scenario | measure | then | now | change |",
      "| --- | --- | ---: | ---: | ---: |"
    ]

    against =
      if ref, do: "the last runs of #{ref} before it", else: "each scenario's last runs before it"

    Enum.join(header ++ rows, "\n") <>
      "\n\nNow: troupe bench #{first["version"]} against #{first["model"]}, #{first["bench"]}. " <>
      "Then: #{against}.\n"
  end

  # The scenario's runs in the last earlier bench that ran it.
  defp before(earlier, scenario) do
    mine = Enum.filter(earlier, &(&1["scenario"] == scenario))

    case mine |> Enum.map(& &1["bench"]) |> List.last() do
      nil -> []
      bench -> Enum.filter(mine, &(&1["bench"] == bench))
    end
  end

  defp rows(scenario, [], now) do
    [row(scenario, "runs", "none earlier", runs(now), "")]
  end

  defp rows(scenario, then, now) do
    measures =
      Enum.zip_with(Live.metrics(then), Live.metrics(now), fn {_name, label, unit, was},
                                                              {_, _, _, is} ->
        row(scenario, label, show(was, unit), show(is, unit), change(was, is, unit))
      end)

    [row(scenario, "runs", runs(then), runs(now), "") | measures]
  end

  # Every scenario both benches ran, together (Decision 775): measures per run and per
  # success, so a bench of three runs a scenario compares with one of one.
  defp overall(scenarios, now, earlier) do
    shared = Enum.filter(scenarios, &(before(earlier, &1) != []))

    if length(shared) < 2 do
      []
    else
      then = Enum.flat_map(shared, &before(earlier, &1))
      now = Enum.filter(now, &(&1["scenario"] in shared))
      count = "#{length(shared)} scenarios"

      measures =
        Enum.zip_with(Live.overall(then), Live.overall(now), fn {_name, label, unit, was},
                                                                {_, _, _, is} ->
          row("all", label, show(was, unit), show(is, unit), change(was, is, unit))
        end)

      [row("all", "scenarios in both", count, count, "") | measures]
    end
  end

  defp row(scenario, measure, then, now, change),
    do: "| #{scenario} | #{measure} | #{then} | #{now} | #{change} |"

  defp runs([run | _] = runs), do: "#{length(runs)}, #{run["version"]}, #{run["model"]}"

  defp show(nil, _unit), do: ""
  defp show(value, "$"), do: "$" <> :erlang.float_to_binary(value / 1, decimals: 4)
  defp show(value, "share"), do: to_string(value)
  defp show(value, unit), do: "#{value} #{unit}"

  # A share by how much it moved; anything else by how much, of what it was.
  defp change(was, is, _unit) when is_nil(was) or is_nil(is), do: ""
  defp change(was, is, "share"), do: signed(Float.round(is - was, 3))
  defp change(was, was, _unit), do: "0%"
  defp change(was, _is, _unit) when was == 0, do: ""
  defp change(was, is, _unit), do: signed(round((is - was) * 100 / was)) <> "%"

  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n), do: to_string(n)
end
