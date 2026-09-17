defmodule Troupe.Plane.TeamBudget do
  @moduledoc """
  One actor per team, deciding whether there is money left.

  One rung of the ladder `Troupe.Plane.Budget` walks: the platform's ceiling above it,
  a person's below. This one answers only for the team, and writes nothing — the
  reservation row is `Budget`'s to write once every rung has said yes.

  The same shape as `Troupe.Plane.Placement` and for the same reason: deciding whether
  a reservation fits is a read-decide-write over the ledger, and two replicas doing it
  at once is how a team spends more than it has.

  Reserving is not spending. A session reserves a slice up front and the ledger records
  what it actually cost; the reservation is released when the session goes dormant or
  is erased. What is *committed* — the sum of usage records — is what a nightly
  reconciliation against the gateway compares, and reservations never appear in it.
  """

  use GenServer

  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.{Ledger, Singleton}
  alias Troupe.Plane.Ledger.Cache

  @enforce_keys [:team_id]
  defstruct [:team_id, :budget_micros, spent_micros: 0, reserved_micros: 0, reservations: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Reserve a session's slice of a team's budget.

  `{:error, :over_budget}` with what is left, so a caller can say how much rather than
  only that there is none.
  """
  @spec reserve(Team.t() | Ecto.UUID.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(team, session_id, amount_micros) do
    Singleton.call(__MODULE__, team_id(team), {:reserve, session_id, amount_micros})
  end

  @doc "Give a reservation back."
  @spec release(Team.t() | Ecto.UUID.t(), String.t()) :: :ok
  def release(team, session_id) do
    Singleton.call(__MODULE__, team_id(team), {:release, session_id})
  end

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

  @doc "What this actor believes, for tests and diagnostics."
  @spec inspect_state(Team.t() | Ecto.UUID.t()) :: map()
  def inspect_state(team), do: Singleton.call(__MODULE__, team_id(team), :inspect)

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  @impl GenServer
  def init(opts) do
    team_id = Keyword.fetch!(opts, :key)
    Process.set_label("troupe budget #{team_id}")
    {:ok, %__MODULE__{team_id: team_id}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl GenServer
  def handle_call({:reserve, session_id, amount}, _from, state) do
    # Reloaded rather than trusted. The count this actor last had is one a pod restart, a
    # replica handover or another rung's release can have moved under it, and a ceiling
    # decided from a stale count is a ceiling that is wrong for as long as the process
    # lives — which is the fault the placement actor already taught us once.
    state = load(state)

    cond do
      Map.has_key?(state.reservations, session_id) ->
        # Reserving twice for one session is a retry, not a second slice.
        {:reply, {:ok, summary(state)}, state}

      unlimited?(state) or
          state.spent_micros + state.reserved_micros + amount <= state.budget_micros ->
        # Held, not written. One promise is one row, and `Troupe.Plane.Budget` writes it
        # once every rung of the ladder has agreed — a row written here would be counted
        # by the rungs after this one as though somebody else had made it.
        state = %{
          state
          | reserved_micros: state.reserved_micros + amount,
            reservations: Map.put(state.reservations, session_id, amount)
        }

        {:reply, {:ok, summary(state)}, state}

      true ->
        {:reply, {:error, {:over_budget, summary(state)}}, state}
    end
  end

  def handle_call({:release, session_id}, _from, state) do
    {amount, reservations} = Map.pop(state.reservations, session_id, 0)

    state = %{
      state
      | reserved_micros: max(state.reserved_micros - amount, 0),
        reservations: reservations
    }

    {:reply, :ok, state}
  end

  def handle_call({:record, attrs}, _from, state) do
    case Ledger.record(Map.put(attrs, :team_id, state.team_id)) do
      {:ok, record} ->
        Cache.invalidate(state.team_id)
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
  def handle_call({:record_batch, records}, _from, state) do
    {state, result} =
      records
      |> Enum.sort_by(& &1[:seq])
      |> Enum.reduce_while({state, %{recorded: 0, duplicates: 0, seq: 0}}, fn record,
                                                                              {acc, tally} ->
        {seq, attrs} = Map.pop(record, :seq, 0)

        case Ledger.record(Map.put(attrs, :team_id, acc.team_id)) do
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
        if tally.recorded > 0, do: Cache.invalidate(state.team_id)
        {:reply, {:ok, tally}, state}
    end
  end

  def handle_call(:inspect, _from, state), do: {:reply, summary(state), state}

  # -- state ------------------------------------------------------------------

  # Reloaded from the ledger, which is what makes respawning on another replica safe.
  # What this actor is already holding is merged over what the ledger knows, so a session
  # granted a moment ago and not yet written is counted once rather than twice.
  defp load(state) do
    reservations = Map.merge(Ledger.open_reservations(state.team_id), state.reservations)

    %{
      state
      | budget_micros: Ledger.budget_micros(state.team_id),
        spent_micros: Ledger.spent_micros(state.team_id),
        reserved_micros: reservations |> Map.values() |> Enum.sum(),
        reservations: reservations
    }
  end

  # A budget of zero means no limit rather than no money: a team that has not been
  # given one should not be unable to work.
  defp unlimited?(%__MODULE__{budget_micros: budget}), do: is_nil(budget) or budget <= 0

  defp summary(state) do
    %{
      team_id: state.team_id,
      budget_micros: state.budget_micros,
      spent_micros: state.spent_micros,
      reserved_micros: state.reserved_micros,
      remaining_micros:
        if(unlimited?(state),
          do: :unlimited,
          else: max(state.budget_micros - state.spent_micros - state.reserved_micros, 0)
        ),
      node: node()
    }
  end
end
