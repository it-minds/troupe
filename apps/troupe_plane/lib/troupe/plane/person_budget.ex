defmodule Troupe.Plane.PersonBudget do
  @moduledoc """
  One actor per person, deciding whether *they* have anything left.

  `Troupe.Plane.TeamBudget`'s sibling, in the same shape and for the same reason: two
  replicas deciding whether a reservation fits is how somebody spends more than they
  have. What differs is the scope and what follows from it.

  ## A person is not in one team

  A team's spend is a column on a row the team owns. A person's is a sum across every
  team they are in, so this actor is keyed by subject and reads across the whole ledger.
  That is the only shape that makes a cap mean anything: a cap per team per person would
  be a cap somebody clears by being added to a second team.

  ## Whose spend a principal's is

  A session a trigger started is attributed to the principal's **sponsor**, not to the
  principal. A cap that counted only what somebody typed into would be a cap they step
  around by writing a trigger, and the sponsor is exactly the person who is answerable
  for what it does.

  ## Why it does not cache what has been spent

  `TeamBudget` keeps a running total in process and moves it as charges land, which is
  right for a number one actor owns end to end. This one does not: charges arrive
  through the team's actor, and a per-person total kept here would drift from the ledger
  the first time one did. So it re-reads on each reserve. That is one query per session
  create — not a hot path — and it is always right.

  It is also the lesson the placement actor already taught, at a cost: a count held in a
  process and not reloaded is a count that becomes permanently wrong the first time
  anything happens it did not see.
  """

  use GenServer

  alias Troupe.Plane.{Ledger, Singleton}

  @enforce_keys [:subject]
  defstruct [:subject, :budget_micros, reservations: %{}, spent_micros: 0]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Whether this person can promise `amount_micros` more.

  Decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed — a row written by the first rung
  would be counted by the rungs after it as though somebody else had made it.
  """
  @spec reserve(String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(subject, session_id, amount_micros) do
    call(subject, {:reserve, session_id, amount_micros})
  end

  @doc """
  Whether this person has a ceiling at all.

  One indexed lookup, and no actor. A person with no cap — which is everybody until
  somebody sets one — has nothing for this rung to decide, and asking anyway would put a
  `:global` round trip and a pair of aggregates on the path of every session create for an
  answer that was always going to be yes.
  """
  @spec capped?(String.t()) :: boolean()
  def capped?(subject) do
    case Ledger.person_budget_micros(subject) do
      cap when is_integer(cap) and cap > 0 -> true
      _none -> false
    end
  end

  @doc "Give a promise back."
  @spec release(String.t(), String.t()) :: :ok
  def release(subject, session_id), do: call(subject, {:release, session_id})

  @doc "What this person's ceiling is and how much of it is gone."
  @spec inspect_state(String.t()) :: map()
  def inspect_state(subject), do: call(subject, :inspect)

  defp call(subject, message), do: Singleton.call(__MODULE__, subject, message)

  @impl GenServer
  def init(opts) do
    subject = Keyword.fetch!(opts, :key)
    Process.set_label("troupe person budget #{subject}")
    {:ok, %__MODULE__{subject: subject}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl GenServer
  def handle_call({:reserve, session_id, amount}, _from, state) do
    # Reloaded here rather than trusted: what this actor last saw is not what the ledger
    # says once a charge has landed through the team's actor.
    state = load(state)

    cond do
      Map.has_key?(state.reservations, session_id) ->
        {:reply, {:ok, summary(state)}, state}

      unlimited?(state) or state.spent_micros + reserved(state) + amount <= state.budget_micros ->
        state = %{state | reservations: Map.put(state.reservations, session_id, amount)}
        {:reply, {:ok, summary(state)}, state}

      true ->
        {:reply, {:error, {:over_budget, summary(state)}}, state}
    end
  end

  def handle_call({:release, session_id}, _from, state) do
    {:reply, :ok, %{state | reservations: Map.delete(state.reservations, session_id)}}
  end

  def handle_call(:inspect, _from, state) do
    state = load(state)
    {:reply, summary(state), state}
  end

  # -- state ------------------------------------------------------------------

  # Reservations the ledger knows about are merged *under* what this actor is holding, so
  # a session granted a moment ago and not yet written is counted once rather than twice.
  defp load(state) do
    %{
      state
      | budget_micros: Ledger.person_budget_micros(state.subject),
        spent_micros: Ledger.spent_micros_for(state.subject),
        reservations:
          Map.merge(Ledger.open_reservations_for(state.subject), state.reservations)
    }
  end

  defp reserved(state), do: state.reservations |> Map.values() |> Enum.sum()

  # Zero means no limit rather than no money, exactly as a team's does: somebody who has
  # never been given a cap should not be unable to work.
  defp unlimited?(%__MODULE__{budget_micros: budget}), do: is_nil(budget) or budget <= 0

  defp summary(state) do
    %{
      scope: :person,
      subject: state.subject,
      budget_micros: state.budget_micros,
      spent_micros: state.spent_micros,
      reserved_micros: reserved(state),
      remaining_micros:
        if(unlimited?(state),
          do: :unlimited,
          else: max(state.budget_micros - state.spent_micros - reserved(state), 0)
        ),
      node: node()
    }
  end
end
