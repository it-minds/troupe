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
  alias Troupe.Plane.Ledger.{Cache, Reservation, UsageRecord}
  alias Troupe.Plane.Repo

  @doc """
  Record what one model call cost.

  Idempotent on the gateway's request id, and a repeat is a *success* rather than an
  error: a worker replaying a queued report after a reconnect has done nothing wrong and
  must not be told it has. `{:duplicate, existing}` says which case it was, because a
  caller keeping a running total needs to know whether to add this one — and hands back
  the record that stands, which is the first one. What the gateway billed is what the
  first report said; a second report with different numbers does not overwrite it.
  """
  @spec record(map()) ::
          {:ok, UsageRecord.t()} | {:duplicate, UsageRecord.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    attrs = Map.put_new(attrs, :occurred_at, DateTime.utc_now())

    %UsageRecord{}
    |> UsageRecord.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        if duplicate?(changeset), do: {:duplicate, existing(attrs)}, else: {:error, changeset}
    end
  end

  defp existing(attrs) do
    Repo.get_by(UsageRecord,
      gateway_request_id: attrs[:gateway_request_id] || attrs["gateway_request_id"]
    )
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
    Cache.fetch({team_id, :spent_micros}, fn ->
      query =
        from(u in UsageRecord,
          where: u.team_id == ^team_id,
          select: type(coalesce(sum(u.cost_micros), 0), :integer)
        )

      Repo.one(query) || 0
    end)
  end

  @doc """
  What a team spent in a window, grouped.

  `:model`, `:owner_subject` or `:session_id` — the three questions a panel asks and the
  three columns worth grouping by. Rows come back newest spend first, because a list of
  a hundred models is read from the top.

  Cached, and invalidated by the one process that writes the table, so a page that is
  reloaded twice in a minute costs one aggregate rather than two.
  """
  @spec breakdown(Ecto.UUID.t(), :model | :owner_subject | :session_id, keyword()) :: [map()]
  def breakdown(team_id, group_by, opts \\ [])
      when group_by in [:model, :owner_subject, :session_id] do
    from = Keyword.get(opts, :from, ~U[1970-01-01 00:00:00.000000Z])
    to = Keyword.get(opts, :to, DateTime.utc_now())

    Cache.fetch({team_id, {:breakdown, group_by, from, to}}, fn ->
      Repo.all(
        from(u in UsageRecord,
          where: u.team_id == ^team_id and u.occurred_at >= ^from and u.occurred_at < ^to,
          group_by: field(u, ^group_by),
          order_by: [desc: coalesce(sum(u.cost_micros), 0)],
          select: %{
            key: field(u, ^group_by),
            calls: count(u.id),
            input_tokens: type(coalesce(sum(u.input_tokens), 0), :integer),
            output_tokens: type(coalesce(sum(u.output_tokens), 0), :integer),
            cost_micros: type(coalesce(sum(u.cost_micros), 0), :integer)
          }
        )
      )
    end)
  end

  @doc """
  What one session cost.

  Read from the ledger rather than from the session row's `cost_micros`, which is the
  worker's own running total and stops moving when the pod does. These are the charges.
  """
  @spec session_cost_micros(String.t()) :: non_neg_integer()
  def session_cost_micros(session_id) do
    query =
      from(u in UsageRecord,
        where: u.session_id == ^session_id,
        select: type(coalesce(sum(u.cost_micros), 0), :integer)
      )

    Repo.one(query) || 0
  end

  @doc "A team's budget, or `0` for no limit."
  @spec budget_micros(Ecto.UUID.t()) :: non_neg_integer()
  def budget_micros(team_id) do
    Repo.one(from(t in Team, where: t.id == ^team_id, select: t.budget_micros)) || 0
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
      from(r in Reservation,
        where: r.team_id == ^team_id and is_nil(r.released_at),
        select: {r.session_id, r.amount_micros}
      )
    )
    |> Map.new()
  end

  @doc "Every usage record for a team in a window, for reconciliation and reporting."
  @spec records(Ecto.UUID.t(), DateTime.t(), DateTime.t()) :: [UsageRecord.t()]
  def records(team_id, from, to) do
    Repo.all(
      from(u in UsageRecord,
        where: u.team_id == ^team_id and u.occurred_at >= ^from and u.occurred_at < ^to,
        order_by: u.occurred_at
      )
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
      from(u in UsageRecord,
        where: u.occurred_at >= ^from and u.occurred_at < ^to,
        select: u.gateway_request_id
      )
    )
    |> MapSet.new()
  end
end
