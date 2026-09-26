defmodule Troupe.Plane.Budget do
  @moduledoc """
  Every ceiling a reservation has to clear, and which one refused.

      deployment  ≥  platform  ≥  team  ≥  person  ≥  session slice

  A cap used to belong to a team and to nothing else, which left the two things people
  actually ask for unsayable: "this contractor may spend a hundred a month, whatever
  team they are in" and "nobody at all may take this deployment past a number".

  ## A month is the calendar month in UTC

  The person's and the platform's rungs count what was spent since midnight UTC on the
  1st, so a person or a deployment at its ceiling starts sessions again then rather than
  when somebody raises it. A team's rung counts its own `budget_period`: the same month
  for `monthly`, everything for `never`. Every rung's summary names its period
  (`budget_period`), because a figure without the period it covers cannot be read
  against its ceiling.

  ## Absence means everything

  A scope with no cap set does not participate. Zero and `nil` both mean no ceiling,
  exactly as an entitlement's absence does — a team that has never been given a budget
  should not be unable to work, and neither should a person.

  ## The tightest one refuses, and says so

  The rungs are walked narrowest first, so the refusal a caller sees is the one closest
  to them: a person at their own cap inside a team with room to spare is told about
  their own cap, which is the thing they can do something about. "Budget exhausted"
  without a scope is a support ticket; "your own cap, and your team has plenty" is an
  answer.

  ## One promise is one row

  Each rung decides and *holds*; none of them writes. The row is written here, once,
  after every rung has agreed — a row written by the first rung would be read by the
  rungs after it as a promise somebody else had made, and the reservation would be
  counted against itself.

  A rung that refuses after earlier ones agreed is unwound before the refusal is
  returned. That is the same compensating shape `session.create` already uses when a pod
  declines a session the plane had found room for, and without it a person at their own
  cap would slowly eat their team's.
  """

  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.{Ledger, PersonBudget, PlatformBudget, TeamBudget}

  @type scope :: :person | :team | :platform | :deployment
  @type rung :: %{
          scope: scope(),
          capped?: (-> boolean()),
          reserve: (String.t(), non_neg_integer() -> {:ok, map()} | {:error, term()}),
          release: (String.t() -> :ok),
          inspect: (-> map())
        }

  @doc """
  Reserve a session's slice against every ceiling that applies.

  `{:error, {:over_budget, scope, summary}}` names the rung that refused and what it has
  left, so a caller can say which cap and by how much rather than only that there is no
  money.
  """
  @spec reserve(Team.t() | Ecto.UUID.t() | nil, String.t(), String.t() | nil, non_neg_integer()) ::
          {:ok, [map()]} | {:error, {:over_budget, scope(), map()}}
  def reserve(team, session_id, owner_subject, amount_micros) do
    case walk(rungs(team, owner_subject), session_id, amount_micros, []) do
      {:ok, summaries} ->
        # Every rung said yes, so the promise becomes a row every replica can see.
        {:ok, _} = Ledger.reserve(team_id(team), session_id, owner_subject, amount_micros)
        {:ok, summaries}

      {:error, _refusal} = error ->
        error
    end
  end

  @doc "Give a session's promise back at every rung, and drop the row."
  @spec release(Team.t() | Ecto.UUID.t() | nil, String.t(), String.t() | nil) :: :ok
  def release(team, session_id, owner_subject) do
    Ledger.release(team_id(team), session_id)
    Enum.each(rungs(team, owner_subject), & &1.release.(session_id))
    :ok
  end

  @doc """
  Every ceiling that applies here, narrowest first.

  What the console shows beside a refusal: somebody told they are over budget should be
  able to see which of four numbers they are over without asking anybody.
  """
  @spec ceilings(Team.t() | Ecto.UUID.t() | nil, String.t() | nil) :: [map()]
  def ceilings(team, owner_subject) do
    team
    |> rungs(owner_subject)
    |> Enum.map(fn rung -> Map.put(rung.inspect.(), :scope, rung.scope) end)
  end

  # -- the rungs --------------------------------------------------------------

  # Narrowest first. A session with no team and a caller with no subject each drop their
  # rung rather than being given a ceiling of nothing: a private session on somebody's
  # laptop has no team and spends no team's money.
  @spec rungs(Team.t() | Ecto.UUID.t() | nil, String.t() | nil) :: [rung()]
  defp rungs(team, owner_subject) do
    person_rung(owner_subject) ++ team_rung(team) ++ [platform_rung()]
  end

  defp person_rung(subject) when is_binary(subject) do
    [
      %{
        scope: :person,
        capped?: fn -> PersonBudget.capped?(subject) end,
        reserve: &PersonBudget.reserve(subject, &1, &2),
        release: &PersonBudget.release(subject, &1),
        inspect: fn -> PersonBudget.inspect_state(subject) end
      }
    ]
  end

  defp person_rung(_none), do: []

  defp team_rung(nil), do: []

  defp team_rung(team) do
    id = team_id(team)

    [
      %{
        scope: :team,
        # Always asked. A team's ceiling is the one people actually set, and the actor is
        # per team rather than per deployment — so it is neither a shared bottleneck nor a
        # rung that is usually unset.
        capped?: fn -> true end,
        reserve: &TeamBudget.reserve(id, &1, &2),
        release: &TeamBudget.release(id, &1),
        inspect: fn -> TeamBudget.inspect_state(id) end
      }
    ]
  end

  # The deployment's ceiling and the platform's are two caps over one number, so they are
  # one rung; the summary says which of the two bound.
  defp platform_rung do
    %{
      scope: :platform,
      capped?: &PlatformBudget.capped?/0,
      reserve: &PlatformBudget.reserve/2,
      release: &PlatformBudget.release/1,
      inspect: &PlatformBudget.inspect_state/0
    }
  end

  defp walk([], _session_id, _amount, taken) do
    {:ok, taken |> Enum.reverse() |> Enum.map(fn {_rung, summary} -> summary end)}
  end

  # A rung nobody has set a ceiling at is skipped, not consulted and waved through. The
  # difference is a `:global` round trip and a pair of aggregates per session create — and
  # for the platform rung it is *one* actor for the whole deployment, so fifty concurrent
  # creates queue behind fifty full-ledger sums to be told what absence already says.
  defp walk([rung | rest], session_id, amount, taken) do
    if rung.capped?.() do
      take(rung, rest, session_id, amount, taken)
    else
      walk(rest, session_id, amount, taken)
    end
  end

  defp take(rung, rest, session_id, amount, taken) do
    case rung.reserve.(session_id, amount) do
      {:ok, summary} ->
        walk(rest, session_id, amount, [{rung, Map.put(summary, :scope, rung.scope)} | taken])

      {:error, {:over_budget, summary}} ->
        Enum.each(taken, fn {held, _summary} -> held.release.(session_id) end)
        {:error, {:over_budget, refused_by(summary, rung), Map.put(summary, :scope, rung.scope)}}
    end
  end

  # The platform rung holds two ceilings and says which one bound, so the scope a caller
  # is told is `deployment` or `platform` rather than the rung's own name.
  defp refused_by(%{bound_by: bound}, _rung) when is_atom(bound) and not is_nil(bound), do: bound
  defp refused_by(_summary, rung), do: rung.scope

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id
  defp team_id(nil), do: nil
end
