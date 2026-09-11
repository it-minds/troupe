defmodule Troupe.Plane.Ledger do
  @moduledoc """
  What was spent, and what is promised.

  Two tables with different jobs. `usage_records` is append-only and unique on the
  gateway's request id: it is the record of what actually happened, and the nightly
  reconciliation against the gateway joins on that id. `budget_reservations` is what a
  running session has promised to spend, held while it runs and released when it stops.

  The uniqueness is load-bearing. A worker that loses the plane keeps sealing and
  replays its reports when it comes back, so the same request is reported more than
  once — and a ledger that counted it twice would make a team look over budget for
  having survived an outage.
  """

  import Ecto.Query

  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Ledger.{Reservation, UsageRecord}
  alias Troupe.Plane.Repo

  @doc "Record what one model call cost. Idempotent on the gateway's request id."
  @spec record(map()) :: {:ok, UsageRecord.t()} | {:error, :duplicate | Ecto.Changeset.t()}
  def record(attrs) do
    attrs = Map.put_new(attrs, :occurred_at, DateTime.utc_now())

    %UsageRecord{}
    |> UsageRecord.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        if duplicate?(changeset), do: {:error, :duplicate}, else: {:error, changeset}
    end
  end

  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
      field == :gateway_request_id and opts[:constraint] == :unique
    end)
  end

  @doc """
  What a team has actually spent.

  `sum` over a bigint comes back from Postgres as numeric, which Ecto hands over as a
  `Decimal`; arithmetic on that against plain integers silently does the wrong thing,
  so it is cast where it is read rather than everywhere it is used.
  """
  @spec spent_micros(Ecto.UUID.t()) :: non_neg_integer()
  def spent_micros(team_id) do
    query =
      from u in UsageRecord,
        where: u.team_id == ^team_id,
        select: type(coalesce(sum(u.cost_micros), 0), :integer)

    Repo.one(query) || 0
  end

  @doc "A team's budget, or `0` for no limit."
  @spec budget_micros(Ecto.UUID.t()) :: non_neg_integer()
  def budget_micros(team_id) do
    Repo.one(from t in Team, where: t.id == ^team_id, select: t.budget_micros) || 0
  end

  @doc "Promise part of a team's budget to a session."
  @spec reserve(Ecto.UUID.t(), String.t(), non_neg_integer()) ::
          {:ok, Reservation.t()} | {:error, term()}
  def reserve(team_id, session_id, amount_micros) do
    attrs = %{team_id: team_id, session_id: session_id, amount_micros: amount_micros}

    (Repo.get_by(Reservation, session_id: session_id) || %Reservation{})
    |> Reservation.changeset(Map.put(attrs, :released_at, nil))
    |> Repo.insert_or_update()
  end

  @doc "Let a promise go, because the session stopped."
  @spec release(Ecto.UUID.t(), String.t()) :: :ok
  def release(_team_id, session_id) do
    Repo.update_all(
      from(r in Reservation, where: r.session_id == ^session_id and is_nil(r.released_at)),
      set: [released_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Promises a team has outstanding, by session."
  @spec open_reservations(Ecto.UUID.t()) :: %{String.t() => non_neg_integer()}
  def open_reservations(team_id) do
    Repo.all(
      from r in Reservation,
        where: r.team_id == ^team_id and is_nil(r.released_at),
        select: {r.session_id, r.amount_micros}
    )
    |> Map.new()
  end

  @doc "Every usage record for a team in a window, for reconciliation and reporting."
  @spec records(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: [UsageRecord.t()]
  def records(team_id, from, to) do
    Repo.all(
      from u in UsageRecord,
        where: u.team_id == ^team_id and u.occurred_at >= ^from and u.occurred_at < ^to,
        order_by: u.occurred_at
    )
  end

  @doc """
  Gateway request ids the ledger has, in a window.

  What reconciliation compares against the gateway's own list: an id the gateway billed
  and this does not have is drift worth reporting.
  """
  @spec request_ids(DateTime.t(), DateTime.t()) :: MapSet.t(String.t())
  def request_ids(from, to) do
    Repo.all(
      from u in UsageRecord,
        where: u.occurred_at >= ^from and u.occurred_at < ^to,
        select: u.gateway_request_id
    )
    |> MapSet.new()
  end
end
