defmodule Troupe.Plane.TeamBudget do
  @moduledoc """
  The rung that decides whether a team has money left, and the only writer of what its
  sessions actually cost.

  One rung of the ladder `Troupe.Plane.Budget` walks: the platform's ceiling above it,
  a person's below. Reserving is served by `Troupe.Plane.Budget.Rung`, as every rung's
  is, and writes nothing — the reservation row is `Budget`'s to write once every rung has
  said yes.

  What is this rung's own is recording. Reserving is not spending. A session reserves a
  slice up front and the ledger records what it actually cost; the reservation is
  released when the session goes dormant or is erased. What is *committed* — the sum of
  usage records — is what a nightly reconciliation against the gateway compares, and
  reservations never appear in it. Charges are recorded through this one actor per team,
  so the team's ledger cache is invalidated by its only writer.
  """

  use Troupe.Plane.Budget.Rung

  alias Troupe.Plane.Budget.Rung
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.{Ledger, Singleton}
  alias Troupe.Plane.Ledger.Cache

  @doc """
  Reserve a session's slice of a team's budget.

  `{:error, :over_budget}` with what is left, so a caller can say how much rather than
  only that there is none.
  """
  @spec reserve(Team.t() | Ecto.UUID.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(team, session_id, amount_micros) do
    Rung.reserve(__MODULE__, team_id(team), session_id, amount_micros)
  end

  @doc "Give a reservation back."
  @spec release(Team.t() | Ecto.UUID.t(), String.t()) :: :ok
  def release(team, session_id), do: Rung.release(__MODULE__, team_id(team), session_id)

  @doc """
  Record what a model call actually cost.

  Unique on the gateway's request id, so a retry of the report is not a second charge —
  which matters because a worker that loses the plane replays its reports when it comes
  back.
  """
  @spec record(Team.t() | Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def record(team, attrs) do
    Singleton.call(__MODULE__, team_id(team), {:record, attrs})
  end

  @doc """
  Record a batch of them, in one round trip and in sequence order.

  A pod reports what a session spent as a batch rather than a call at a time, so this
  takes the batch: five hundred separate calls into one team's actor would serialise a
  pod's whole flush behind another team's reservation. Returns the highest `seq` that is
  now recorded — including the ones that were already recorded, because a duplicate is
  a success and the watermark must move past it or the pod will send it forever.
  """
  @spec record_batch(Team.t() | Ecto.UUID.t(), [map()]) ::
          {:ok,
           %{recorded: non_neg_integer(), duplicates: non_neg_integer(), seq: non_neg_integer()}}
          | {:error, term()}
  def record_batch(team, records) when is_list(records) do
    Singleton.call(__MODULE__, team_id(team), {:record_batch, records})
  end

  @doc """
  What this actor believes, reloaded, for the Budgets page, tests and diagnostics. What it
  spent is a figure for the period it was last loaded in, and the Budgets page asking
  after midnight on the 1st would otherwise be shown last month's total.
  """
  @spec inspect_state(Team.t() | Ecto.UUID.t()) :: map()
  def inspect_state(team), do: Rung.inspect_state(__MODULE__, team_id(team))

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  @impl Rung
  def label(team_id), do: "troupe budget #{team_id}"

  @impl Rung
  def load(team_id) do
    budget = Ledger.budget_micros(team_id)

    %{
      ceiling: Rung.ceiling(budget),
      budget_micros: budget,
      budget_period: Ledger.budget_period(team_id),
      spent_micros: Ledger.spent_micros(team_id),
      reservations: Ledger.open_reservations(team_id)
    }
  end

  # The period comes with the figure, because a spend without the period it covers cannot
  # be read against anything: the Budgets page labels each ceiling's bar with it.
  @impl Rung
  def summary(team_id, loaded) do
    %{
      team_id: team_id,
      budget_micros: loaded.budget_micros,
      budget_period: loaded.budget_period
    }
  end

  @impl Rung
  def handle_call({:record, attrs}, _from, %Rung{key: team_id} = state) do
    case Ledger.record(Map.put(attrs, :team_id, team_id)) do
      {:ok, record} ->
        Cache.invalidate(team_id)
        {:reply, {:ok, record}, %{state | spent_micros: state.spent_micros + record.cost_micros}}

      # Already recorded: the same gateway request reported twice is one charge, so the
      # running total is not moved.
      {:duplicate, record} ->
        {:reply, {:ok, record}, state}

      error ->
        {:reply, error, state}
    end
  end

  # Sequence order matters: the watermark that comes out of this is only meaningful if
  # everything below it was attempted, so a record that fails to insert stops the
  # watermark there rather than letting the ones after it carry it past a gap.
  def handle_call({:record_batch, records}, _from, %Rung{key: team_id} = state) do
    {state, result} =
      records
      |> Enum.sort_by(& &1[:seq])
      |> Enum.reduce_while({state, %{recorded: 0, duplicates: 0, seq: 0}}, fn record,
                                                                              {acc, tally} ->
        {seq, attrs} = Map.pop(record, :seq, 0)

        case Ledger.record(Map.put(attrs, :team_id, team_id)) do
          {:ok, stored} ->
            acc = %{acc | spent_micros: acc.spent_micros + stored.cost_micros}
            {:cont, {acc, %{tally | recorded: tally.recorded + 1, seq: max(tally.seq, seq)}}}

          {:duplicate, _stored} ->
            {:cont, {acc, %{tally | duplicates: tally.duplicates + 1, seq: max(tally.seq, seq)}}}

          {:error, reason} ->
            {:halt, {acc, {:error, reason}}}
        end
      end)

    case result do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      tally ->
        # Only where something was actually inserted. A batch of duplicates changes no
        # sum, and throwing the cache away for it would make a replaying pod cost every
        # panel in the building a fresh aggregate.
        if tally.recorded > 0, do: Cache.invalidate(team_id)
        {:reply, {:ok, tally}, state}
    end
  end
end
