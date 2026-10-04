defmodule Mix.Tasks.Troupe.Bench do
  @shortdoc "Run the offline bench and fail when a measure is past its budget"

  @moduledoc """
  Run `troupe bench`'s offline suite from a checkout (`Troupe.Bench`, Decision 772).

      mix troupe.bench
      mix troupe.bench --json bench.json

  Prints the report as a Markdown table and exits 1 when a scenario is past a budget in
  `apps/troupe_core/priv/bench/budgets.json` or a check fails. `--json PATH` also writes
  the report as JSON. `scripts/ci` and CI run it; the suite takes a few seconds, against
  a scripted model, and calls nothing outside this VM.

  Only `troupe_core` is started, so it runs from the umbrella's root with no database.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [json: :string])

    # What a session warns about on the way is not the report, and would land in the
    # middle of the table.
    Logger.configure(level: :error)
    {:ok, _apps} = Application.ensure_all_started(:troupe_core)

    {micros, report} = :timer.tc(&Troupe.Bench.run/0)
    if path = opts[:json], do: File.write!(path, Troupe.Bench.json(report))
    IO.write(Troupe.Bench.markdown(report))
    IO.puts("The suite took #{Float.round(micros / 1_000_000, 1)} s.")

    unless Troupe.Bench.passed?(report), do: exit({:shutdown, 1})
  end
end
