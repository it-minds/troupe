defmodule Mix.Tasks.Troupe.Ledger.Reconcile do
  @shortdoc "Compare the plane's ledger with the gateway that did the billing"

  @moduledoc """
  Reconcile a window of the ledger against the LLM gateway's own spend records.

      mix troupe.ledger.reconcile
      mix troupe.ledger.reconcile --days 7
      mix troupe.ledger.reconcile --database-url postgres://…@localhost:5433/troupe_plane

  The nightly job, and the second half of a restore drill: a restored database has lost
  whatever was recorded after the backup, and this is what says by how much.

  Reports; never repairs. A job that silently rewrote the ledger to match the gateway
  would destroy the evidence that they disagreed, and which of them is right is a
  question about the incident rather than about the numbers.

  Exits non-zero when the drift is over the configured threshold, so it can be a cron
  job whose failure means something.
  """

  use Mix.Task

  alias Troupe.Plane.{Reconcile, Repo}

  @impl Mix.Task
  def run(argv) do
    {switches, _positional, _invalid} =
      OptionParser.parse(argv, strict: [days: :integer, database_url: :string])

    {:ok, _} = Application.ensure_all_started(:troupe_plane)
    {:ok, _} = Repo.start_link(repo_opts(switches))

    to = DateTime.utc_now()
    from = DateTime.add(to, -(switches[:days] || 1), :day)

    case Reconcile.fetch(from, to) do
      {:ok, records} -> report(Reconcile.compare(records, from, to))
      {:error, reason} -> Mix.raise("could not reach the gateway: #{inspect(reason)}")
    end
  end

  defp report(result) do
    Mix.shell().info("""
    ledger vs gateway, #{DateTime.to_iso8601(result.from)} .. #{DateTime.to_iso8601(result.to)}

      gateway records : #{result.gateway_records}
      ledger records  : #{result.ledger_records}
      missing         : #{length(result.missing)}   (the gateway billed, we did not record)
      extra           : #{length(result.extra)}   (we recorded, the gateway did not bill)
      mismatched      : #{length(result.mismatched)}   (both have it, costs differ)
      drift           : #{result.drift_micros} micros (threshold #{result.threshold_micros})
    """)

    Enum.each(result.missing, &Mix.shell().info("  missing    #{&1.request_id}  #{&1.cost_micros}"))
    Enum.each(result.extra, &Mix.shell().info("  extra      #{&1.request_id}  #{&1.cost_micros}"))

    Enum.each(
      result.mismatched,
      &Mix.shell().info("  mismatched #{&1.request_id}  gateway #{&1.gateway_micros} vs ledger #{&1.ledger_micros}")
    )

    if result.over_threshold? do
      Mix.raise("drift of #{result.drift_micros} micros is over the threshold")
    end
  end

  defp repo_opts(switches) do
    case switches[:database_url] do
      nil -> []
      url -> [url: url]
    end
  end
end
