defmodule Troupe.CLI.Bench do
  @moduledoc """
  `troupe bench`: the harness's offline suite (root Decision 772, TUI Decision 140),
  printed as a Markdown table, or with `--json` as the JSON report, exiting 1 when a
  measure is past its budget or a check fails.

  The suite runs in this VM, against the harness compiled into this binary, and never
  asks the machine's daemon: what it measures is this build, and a daemon of another
  version would answer for itself. Its model is a script, so it calls nothing outside
  the VM and spends nothing.

  `--live` runs the live scenarios against the person's own provider (root Decision 773,
  TUI Decision 141): it prints what it will do and the most it can spend, on standard
  error, and runs nothing until the person answers yes, or passed `--yes`. `--repeat N`
  runs each scenario N times, `--model` picks another model than the configured one.
  `--suite` picks the live scenarios (`smoke`, the default, or `standard`), `--scenario
  a,b` names them one by one, and `--keep DIR` leaves each run's workspace and session log
  there (TUI Decision 142). Every run goes into the history, and `--compare
  [VERSION|MODEL]` prints the last bench against the one before it, or against a
  version's or a model's.

  `--json` prints the JSON report instead of the table; `--json FILE` writes it to FILE and
  still prints the table, and `--md FILE` writes the table to FILE as well.
  """

  alias Troupe.CLI.{Prompt, Terminal}

  @doc """
  Run what the arguments ask for and print it; returns the exit status.

  `opts` stand in for the person in tests: `:ask`, a function of the question answering
  the line typed, `nil` at the end of input, or `:no_terminal` where nobody can be asked.
  """
  @spec run(Troupe.CLI.args(), keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    cond do
      args.live ->
        live(args, Keyword.get(opts, :ask, &ask/1))

      args.repeat || args.model || args.yes || args.suite || args.scenario || args.keep ->
        refuse("--repeat, --model, --yes, --suite, --scenario and --keep go with --live")

      args.compare ->
        compare(args)

      true ->
        offline(args)
    end
  end

  defp offline(args) do
    {micros, report} = :timer.tc(&Troupe.Bench.run/0)
    output(report, args, "The suite took #{seconds(micros)}.")
    if Troupe.Bench.passed?(report), do: 0, else: 1
  end

  defp live(%{repeat: repeat}, _ask) when is_integer(repeat) and repeat < 1,
    do: refuse("--repeat takes a number of runs, 1 or more")

  defp live(args, ask) do
    case Troupe.Bench.plan(
           repeat: args.repeat || 1,
           model: args.model,
           suite: args.suite,
           only: names(args.scenario),
           keep: args.keep
         ) do
      {:error, why} ->
        refuse(why)

      {:ok, plan} ->
        IO.puts(:stderr, Troupe.Bench.describe_plan(plan))
        answer = if args.yes, do: "y", else: ask.(Troupe.Bench.question(plan))

        if yes?(answer) do
          progress = &IO.puts(:stderr, &1)
          {micros, report} = :timer.tc(fn -> Troupe.Bench.live(plan, progress: progress) end)
          output(report, args, "The live bench took #{seconds(micros)}.")
          if args.compare, do: compare(args)
          if Troupe.Bench.passed?(report), do: 0, else: 1
        else
          IO.puts(:stderr, not_run(answer))
          2
        end
    end
  end

  # `--scenario a,b`: the names, in any order; they run in the report's.
  defp names(nil), do: nil
  defp names(list), do: list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp yes?(answer) when is_binary(answer), do: String.downcase(String.trim(answer)) in ["y", "yes"]
  defp yes?(_none), do: false

  defp not_run(:no_terminal),
    do: "Nothing was run: there is no terminal to ask in. Pass --yes to run it."

  defp not_run(_answer), do: "Nothing was run. Answer y, or pass --yes, to run it."

  # Asked only at a terminal, as `troupe config` asks (TUI Decision 141): a script or a pipe
  # says yes with `--yes`, and on Windows the binary's VM has no reader on standard input
  # at all, so a question there is read key by key (`Troupe.CLI.Prompt`).
  defp ask(question) do
    cond do
      not (Terminal.stdin?() and Terminal.stdout?()) -> :no_terminal
      match?({:win32, _}, :os.type()) -> Prompt.read(question)
      true -> IO.gets(question)
    end
  end

  defp compare(args) do
    case Troupe.Bench.compare(ref: args.ref) do
      {:ok, table} ->
        IO.write(table)
        0

      {:error, why} ->
        refuse(why)
    end
  end

  defp output(report, args, took) do
    if args.json_path, do: File.write!(args.json_path, Troupe.Bench.json(report))
    if args.md, do: File.write!(args.md, Troupe.Bench.markdown(report))

    if args.json and args.json_path == nil do
      IO.write(Troupe.Bench.json(report))
    else
      IO.write(Troupe.Bench.markdown(report))
      IO.puts(took)
    end
  end

  defp refuse(why) do
    IO.puts(:stderr, "troupe bench: " <> why)
    2
  end

  defp seconds(micros), do: "#{Float.round(micros / 1_000_000, 1)} s"
end
