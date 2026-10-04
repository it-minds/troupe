defmodule Troupe.CLI.Bench do
  @moduledoc """
  `troupe bench`: the harness's offline suite (root Decision 772, TUI Decision 140),
  printed as a Markdown table, or with `--json` as the JSON report, exiting 1 when a
  measure is past its budget or a check fails.

  The suite runs in this VM, against the harness compiled into this binary, and never
  asks the machine's daemon: what it measures is this build, and a daemon of another
  version would answer for itself. Its model is a script, so it calls nothing outside
  the VM and spends nothing.

  `--live`, the same suite against the person's own provider, is a flag reserved for
  that, refused until it exists.
  """

  @doc "Run the suite and print it; returns the exit status."
  @spec run(Troupe.CLI.args()) :: non_neg_integer()
  def run(%{live: true}) do
    IO.puts(:stderr, "troupe bench --live: not yet. `troupe bench` runs the offline suite.")
    2
  end

  def run(args) do
    {micros, report} = :timer.tc(&Troupe.Bench.run/0)

    if args.json do
      IO.write(Troupe.Bench.json(report))
    else
      IO.write(Troupe.Bench.markdown(report))
      IO.puts("The suite took #{Float.round(micros / 1_000_000, 1)} s.")
    end

    if Troupe.Bench.passed?(report), do: 0, else: 1
  end
end
