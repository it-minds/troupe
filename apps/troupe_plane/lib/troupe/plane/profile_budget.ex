defmodule Troupe.Plane.ProfileBudget do
  @moduledoc """
  The rung that decides whether a worker profile's sessions have anything left: one actor
  per profile, served by `Troupe.Plane.Budget.Rung` as every rung is.

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

  ## Why it re-reads what has been spent

  As a person's: the charges arrive through the team's actor, so a total kept here would
  drift from the ledger. The rung reloads on each reserve.
  """

  use Troupe.Plane.Budget.Rung

  alias Troupe.Plane.Budget.Rung
  alias Troupe.Plane.{Fleet, Ledger}
  alias Troupe.Plane.Fleet.Extends

  @doc """
  Whether this profile's sessions can promise `amount_micros` more.

  Decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed.
  """
  @spec reserve(String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(profile, session_id, amount_micros) do
    Rung.reserve(__MODULE__, profile, session_id, amount_micros)
  end

  @doc """
  Whether this profile has a ceiling at all: one indexed lookup and no actor, so a profile
  with none, which is every profile until somebody sets one, costs a session create nothing.
  """
  @spec capped?(String.t()) :: boolean()
  def capped?(profile), do: Rung.ceiling(Ledger.profile_budget_micros(profile)) != :unlimited

  @doc "Give a promise back."
  @spec release(String.t(), String.t()) :: :ok
  def release(profile, session_id), do: Rung.release(__MODULE__, profile, session_id)

  @doc "What this profile's ceiling is, which profile set it, and how much of it is gone."
  @spec inspect_state(String.t()) :: map()
  def inspect_state(profile), do: Rung.inspect_state(__MODULE__, profile)

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

  @impl Rung
  def label(profile), do: "troupe profile budget #{profile}"

  @impl Rung
  def load(profile) do
    budget = Ledger.profile_budget_micros(profile)

    %{
      ceiling: Rung.ceiling(budget),
      budget_micros: budget,
      set_by: set_by(profile),
      spent_micros: Ledger.profile_spent_micros(profile),
      reservations: Ledger.open_reservations_for_profile(profile)
    }
  end

  @impl Rung
  def summary(profile, loaded) do
    %{
      scope: :profile,
      profile: profile,
      set_by: loaded.set_by,
      budget_micros: loaded.budget_micros,
      budget_period: "monthly"
    }
  end
end
