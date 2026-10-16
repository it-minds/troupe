defmodule Troupe.Plane.ProfileBudget do
  @moduledoc """
  One actor per worker profile, deciding whether *its* sessions have anything left.

  `Troupe.Plane.PersonBudget`'s sibling, in the same shape and for the same reason: two
  replicas deciding whether a reservation fits is how a profile spends more than it has.

  ## A cap is a month

  What counts is what the profile's sessions spent in the calendar month in UTC, whoever
  started them and in whichever team, so a profile at its ceiling starts sessions again
  from midnight UTC on the 1st. A charge is the profile's through the session it names.

  ## A profile that extends another

  The ceiling read here is the one in effect on the profile's row: the lower of its own and
  its parent's (`Troupe.Plane.Fleet.Extends`). Each profile's sessions are counted against
  its own ceiling, not against its parent's: a standard profile's budget is what the
  standard's own sessions may spend, and a profile that extends it gets the same number at
  most, for its own.

  ## Why it does not cache what has been spent

  As a person's: the charges arrive through the team's actor, so a total kept here would
  drift from the ledger. It re-reads on each reserve.
  """

  use GenServer

  alias Troupe.Plane.{Fleet, Ledger, Singleton}
  alias Troupe.Plane.Fleet.Extends

  @enforce_keys [:profile]
  defstruct [:profile, :budget_micros, :set_by, reservations: %{}, spent_micros: 0]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Whether this profile's sessions can promise `amount_micros` more.

  Decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed.
  """
  @spec reserve(String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(profile, session_id, amount_micros) do
    call(profile, {:reserve, session_id, amount_micros})
  end

  @doc """
  Whether this profile has a ceiling at all: one indexed lookup and no actor, so a profile
  with none, which is every profile until somebody sets one, costs a session create nothing.
  """
  @spec capped?(String.t()) :: boolean()
  def capped?(profile) do
    case Ledger.profile_budget_micros(profile) do
      cap when is_integer(cap) and cap > 0 -> true
      _none -> false
    end
  end

  @doc "Give a promise back."
  @spec release(String.t(), String.t()) :: :ok
  def release(profile, session_id), do: call(profile, {:release, session_id})

  @doc "What this profile's ceiling is, which profile set it, and how much of it is gone."
  @spec inspect_state(String.t()) :: map()
  def inspect_state(profile), do: call(profile, :inspect)

  @doc """
  The profile whose ceiling is in effect on `profile`: its own, or the one it has it from.
  `nil` where there is none.
  """
  @spec set_by(String.t()) :: String.t() | nil
  def set_by(profile) do
    case Fleet.get_profile(profile) do
      %{budget_micros: nil} ->
        nil

      %{extends: nil} ->
        profile

      %{} ->
        case Extends.resolve(profile) do
          {:ok, %{from: from}} -> from["budget_micros"]
          {:error, _reason} -> profile
        end

      nil ->
        nil
    end
  end

  defp call(profile, message), do: Singleton.call(__MODULE__, profile, message)

  @impl GenServer
  def init(opts) do
    profile = Keyword.fetch!(opts, :key)
    Process.set_label("troupe profile budget #{profile}")
    {:ok, %__MODULE__{profile: profile}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl GenServer
  def handle_call({:reserve, session_id, amount}, _from, state) do
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

  # Reservations the ledger knows about are merged *under* what this actor is holding, so
  # a session granted a moment ago and not yet written is counted once rather than twice.
  defp load(state) do
    %{
      state
      | budget_micros: Ledger.profile_budget_micros(state.profile),
        set_by: set_by(state.profile),
        spent_micros: Ledger.profile_spent_micros(state.profile),
        reservations:
          Map.merge(Ledger.open_reservations_for_profile(state.profile), state.reservations)
    }
  end

  defp reserved(state), do: state.reservations |> Map.values() |> Enum.sum()

  defp unlimited?(%__MODULE__{budget_micros: budget}), do: is_nil(budget) or budget <= 0

  defp summary(state) do
    %{
      scope: :profile,
      profile: state.profile,
      set_by: state.set_by,
      budget_micros: state.budget_micros,
      budget_period: "monthly",
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
