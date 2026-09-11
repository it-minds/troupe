defmodule Troupe.Plane.Reconcile do
  @moduledoc """
  Checking the ledger against the gateway that did the billing.

  Two records of the same spend, kept by two systems for different reasons: the gateway
  bills, and the plane budgets. They are supposed to agree, and a nightly job here says
  so or says by how much they do not.

  Drift is not one thing, so it is not reported as one number:

  * **missing** — the gateway billed a request the ledger never recorded. The usual cause
    is a worker that could not reach the plane and whose queued report was dropped, and
    it is the direction that *understates* a team's spend, which is the one that matters
    for a budget.
  * **extra** — the ledger has a request the gateway does not. A worker recorded a call
    the gateway never saw, which usually means a retry counted twice.
  * **mismatched** — both have it and disagree about the cost.

  The comparison is by gateway request id, which is why every usage record carries one
  and the column is unique: it is the only identifier both systems share, and reconciling
  by timestamp and amount would make two identical calls a second apart indistinguishable.

  Reported rather than repaired. A job that silently rewrote the ledger to match the
  gateway would destroy the evidence that they disagreed, and which of them is right is
  a question about the incident rather than about the numbers.
  """

  import Ecto.Query

  alias Troupe.Plane.Ledger.UsageRecord
  alias Troupe.Plane.Repo

  require Logger

  @default_threshold_micros 1_000_000

  @doc """
  Compare a window of the ledger against the gateway's records.

  `records` is what the gateway says, as `[%{"request_id", "cost_micros", ...}]` — fetched
  by `fetch/2` in a cluster, passed in by a test.
  """
  @spec compare([map()], DateTime.t(), DateTime.t(), keyword()) :: map()
  def compare(gateway_records, from, to, opts \\ []) do
    gateway = index_by_request_id(gateway_records)
    ours = ledger_in(from, to)

    gateway_ids = gateway |> Map.keys() |> MapSet.new()
    our_ids = ours |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(gateway_ids, our_ids)
    extra = MapSet.difference(our_ids, gateway_ids)
    mismatched = mismatches(MapSet.intersection(gateway_ids, our_ids), gateway, ours)

    report(%{
      from: from,
      to: to,
      gateway_records: map_size(gateway),
      ledger_records: map_size(ours),
      missing: summarise(missing, gateway),
      extra: summarise(extra, ours),
      mismatched: mismatched,
      threshold_micros: Keyword.get(opts, :threshold_micros, threshold())
    })
  end

  defp report(result) do
    drift =
      Enum.sum(Enum.map(result.missing, & &1.cost_micros)) +
        Enum.sum(Enum.map(result.extra, & &1.cost_micros)) +
        Enum.sum(Enum.map(result.mismatched, &abs(&1.gateway_micros - &1.ledger_micros)))

    result
    |> Map.put(:drift_micros, drift)
    |> Map.put(:clean?, drift == 0)
    |> Map.put(:over_threshold?, drift > result.threshold_micros)
    |> tap(&log/1)
  end

  defp log(%{clean?: true} = result) do
    Logger.info("troupe plane: ledger reconciled clean over #{result.gateway_records} record(s)")
  end

  defp log(result) do
    level = if result.over_threshold?, do: :error, else: :warning

    Logger.log(
      level,
      "troupe plane: ledger drift of #{result.drift_micros} micros — " <>
        "#{length(result.missing)} missing, #{length(result.extra)} extra, " <>
        "#{length(result.mismatched)} mismatched"
    )
  end

  defp mismatches(shared, gateway, ours) do
    shared
    |> Enum.flat_map(fn id ->
      theirs = gateway[id]
      mine = ours[id]

      if cost_of(theirs) == mine.cost_micros do
        []
      else
        [
          %{
            request_id: id,
            gateway_micros: cost_of(theirs),
            ledger_micros: mine.cost_micros,
            session_id: mine.session_id
          }
        ]
      end
    end)
    |> Enum.sort_by(& &1.request_id)
  end

  defp summarise(ids, source) do
    ids
    |> Enum.map(fn id ->
      entry = source[id]

      %{
        request_id: id,
        cost_micros: cost_of(entry),
        session_id: session_of(entry),
        model: model_of(entry)
      }
    end)
    |> Enum.sort_by(& &1.request_id)
  end

  defp cost_of(%UsageRecord{cost_micros: cost}), do: cost
  defp cost_of(%{"cost_micros" => cost}), do: cost
  defp cost_of(_entry), do: 0

  defp session_of(%UsageRecord{session_id: id}), do: id
  defp session_of(%{"session_id" => id}), do: id
  defp session_of(_entry), do: nil

  defp model_of(%UsageRecord{model: model}), do: model
  defp model_of(%{"model" => model}), do: model
  defp model_of(_entry), do: nil

  defp index_by_request_id(records) do
    Map.new(records, fn record -> {record["request_id"] || record["gateway_request_id"], record} end)
  end

  defp ledger_in(from, to) do
    Repo.all(
      from u in UsageRecord,
        where: u.occurred_at >= ^from and u.occurred_at < ^to
    )
    |> Map.new(&{&1.gateway_request_id, &1})
  end

  @doc """
  Fetch the gateway's own spend records for a window.

  A LiteLLM-shaped endpoint by default. Injectable, because a reconcile is exactly the
  job somebody wants to run against a different gateway, and because a test needs one it
  controls.
  """
  @spec fetch(DateTime.t(), DateTime.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch(from, to, opts \\ []) do
    case Keyword.get(opts, :fetcher) || configured_fetcher() do
      nil -> {:error, :no_gateway_configured}
      fetcher when is_function(fetcher, 2) -> fetcher.(from, to)
    end
  end

  defp configured_fetcher do
    case Application.get_env(:troupe_plane, :gateway) do
      nil -> nil
      config -> fn from, to -> http_fetch(config, from, to) end
    end
  end

  defp http_fetch(config, from, to) do
    options = [
      method: :get,
      url: config[:spend_url] || (config[:base_url] && config[:base_url] <> "/spend/logs"),
      params: %{start_date: DateTime.to_iso8601(from), end_date: DateTime.to_iso8601(to)},
      headers: [{"authorization", "Bearer " <> (config[:key] || "")}],
      decode_body: true,
      retry: false
    ]

    case Req.request(options) do
      {:ok, %{status: 200, body: body}} -> {:ok, normalise(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Gateways disagree about whether a list is a list or a list under a key, and about
  # what they call a request id. Normalised here so `compare/4` sees one shape.
  defp normalise(body) when is_list(body), do: Enum.map(body, &normalise_record/1)
  defp normalise(%{"data" => data}) when is_list(data), do: normalise(data)
  defp normalise(%{"logs" => logs}) when is_list(logs), do: normalise(logs)
  defp normalise(_body), do: []

  defp normalise_record(record) do
    %{
      "request_id" => record["request_id"] || record["id"] || record["gateway_request_id"],
      "cost_micros" => micros_of(record),
      "session_id" => get_in(record, ["metadata", "troupe_session_id"]) || record["session_id"],
      "model" => record["model"]
    }
  end

  # Gateways report money in whole currency units as a float. Micros are integers here
  # for the reason money is always integers: a budget compared with floats is a budget
  # that is occasionally off by a fraction of a cent for no reason anyone can find.
  defp micros_of(%{"cost_micros" => micros}) when is_integer(micros), do: micros
  defp micros_of(%{"spend" => spend}) when is_number(spend), do: round(spend * 1_000_000)
  defp micros_of(%{"cost" => cost}) when is_number(cost), do: round(cost * 1_000_000)
  defp micros_of(_record), do: 0

  defp threshold do
    Application.get_env(:troupe_plane, :reconcile_threshold_micros, @default_threshold_micros)
  end

  @doc "Run last night's reconcile: the twenty-four hours ending at midnight UTC today."
  @spec nightly(keyword()) :: {:ok, map()} | {:error, term()}
  def nightly(opts \\ []) do
    to = Date.utc_today() |> DateTime.new!(~T[00:00:00.000000])
    from = DateTime.add(to, -1, :day)

    with {:ok, records} <- fetch(from, to, opts) do
      {:ok, compare(records, from, to, opts)}
    end
  end
end
