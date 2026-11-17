defmodule Troupe.Plane.PersonBudget do
  @moduledoc """
  The rung that decides whether a *person* has anything left: one actor per person, served
  by `Troupe.Plane.Budget.Rung` as every rung is. What is its own is the scope and what
  follows from it.

  ## A person is not in one team

  A team's spend is a column on a row the team owns. A person's is a sum across every
  team they are in, so this actor is keyed by subject and reads across the whole ledger.
  That is the only shape that makes a cap mean anything: a cap per team per person would
  be a cap somebody clears by being added to a second team.

  ## A cap is a month

  What counts is what they spent in the calendar month in UTC, so somebody at their cap
  can start sessions again from midnight UTC on the 1st. The month is the person's own
  period rather than any team's: a person in a `monthly` team and a `never` one has one
  cap, and it cannot follow both.

  ## Whose spend a principal's is

  A session a trigger started is attributed to the principal's **sponsor**, not to the
  principal. A cap that counted only what somebody typed into would be a cap they step
  around by writing a trigger, and the sponsor is exactly the person who is answerable
  for what it does.

  ## Why it re-reads what has been spent

  Charges arrive through the team's actor, so a per-person total kept here would drift
  from the ledger the first time one did. The rung reloads on each reserve.
  """

  use Troupe.Plane.Budget.Rung

  alias Troupe.Plane.Budget.Rung
  alias Troupe.Plane.Ledger

  @doc """
  Whether this person can promise `amount_micros` more.

  Decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed.
  """
  @spec reserve(String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(subject, session_id, amount_micros) do
    Rung.reserve(__MODULE__, subject, session_id, amount_micros)
  end

  @doc """
  Whether this person has a ceiling at all.

  One indexed lookup, and no actor. A person with no cap — which is everybody until
  somebody sets one — has nothing for this rung to decide, and asking anyway would put a
  `:global` round trip and a pair of aggregates on the path of every session create for an
  answer that was always going to be yes.
  """
  @spec capped?(String.t()) :: boolean()
  def capped?(subject), do: Rung.ceiling(Ledger.person_budget_micros(subject)) != :unlimited

  @doc "Give a promise back."
  @spec release(String.t(), String.t()) :: :ok
  def release(subject, session_id), do: Rung.release(__MODULE__, subject, session_id)

  @doc "What this person's ceiling is and how much of it is gone."
  @spec inspect_state(String.t()) :: map()
  def inspect_state(subject), do: Rung.inspect_state(__MODULE__, subject)

  @impl Rung
  def label(subject), do: "troupe person budget #{subject}"

  @impl Rung
  def load(subject) do
    budget = Ledger.person_budget_micros(subject)

    %{
      ceiling: Rung.ceiling(budget),
      budget_micros: budget,
      spent_micros: Ledger.spent_micros_for(subject),
      reservations: Ledger.open_reservations_for(subject)
    }
  end

  @impl Rung
  def summary(subject, loaded) do
    %{
      scope: :person,
      subject: subject,
      budget_micros: loaded.budget_micros,
      budget_period: "monthly"
    }
  end
end
