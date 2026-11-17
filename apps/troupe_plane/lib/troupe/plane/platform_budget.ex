defmodule Troupe.Plane.PlatformBudget do
  @moduledoc """
  The two ceilings above every team: what the deployment allows, and what a platform
  admin allows within that.

  One actor, one key, because both ceilings are over the same number — everything this
  plane has spent and promised, across every team. Two actors for two caps on one total
  would be two answers to one question. Served by `Troupe.Plane.Budget.Rung`, as every
  rung is.

  Spent this month: both caps count the calendar month in UTC and turn over at midnight
  UTC on the 1st, as a person's does. A deployment at its ceiling starts sessions again
  on the 1st rather than staying stopped until somebody raises the number.

  ## A stored ceiling may only narrow

  The deployment's cap comes from a Helm value (`plane.deploymentBudgetMicros`, which the
  chart passes as `TROUPE_DEPLOYMENT_BUDGET_MICROS`) and is the floor of the argument: an
  operator who could raise it from inside the console could raise it past whatever the
  people paying for this agreed to. So a platform admin's cap applies when it is
  *tighter* and is ignored when it is not — the ladder's rule, a lower rung may only
  narrow, made concrete in the one place it is about money.

  The refusal names which of the two bound, because "over budget" without a scope is a
  support ticket and "the platform cap, which is tighter than the deployment's" is an
  instruction.
  """

  use Troupe.Plane.Budget.Rung

  alias Troupe.Plane.Budget.Rung
  alias Troupe.Plane.{Ledger, Settings}

  # One of a kind: there is one platform.
  @key :platform

  @doc """
  Whether this deployment can promise `amount_micros` more.

  Decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed.
  """
  @spec reserve(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(session_id, amount_micros) do
    Rung.reserve(__MODULE__, @key, session_id, amount_micros)
  end

  @doc "Give a promise back."
  @spec release(String.t()) :: :ok
  def release(session_id), do: Rung.release(__MODULE__, @key, session_id)

  @doc "Both ceilings, which one binds, and how much of it is gone."
  @spec inspect_state() :: map()
  def inspect_state, do: Rung.inspect_state(__MODULE__, @key)

  @doc """
  Whether anybody has set a ceiling here at all.

  Cheap on purpose: two settings and no database. A deployment with no cap and no platform
  cap is the common case, and this rung then has nothing to decide — so
  `Troupe.Plane.Budget` skips it rather than queuing every session create in the whole
  deployment behind one actor summing the whole ledger to answer "yes, fine".

  That is not an optimisation bolted on: absence means everything is already the rule, and
  a rung with no opinion should cost nothing to ask.
  """
  @spec capped?() :: boolean()
  def capped?, do: ceiling() != :unlimited

  @doc """
  The tighter of a set of ceilings, treating zero and `nil` as no ceiling at all.

  The ladder's rule in one function, and worth being able to test on its own: an unset
  cap does not participate — absence means everything, exactly as an entitlement's
  absence does — and of two that are set the smaller wins whichever rung wrote it.
  """
  @spec tightest(keyword()) :: {atom(), pos_integer()} | :unlimited
  def tightest(caps) do
    caps
    |> Enum.filter(fn {_scope, cap} -> is_integer(cap) and cap > 0 end)
    |> Enum.min_by(fn {_scope, cap} -> cap end, fn -> :unlimited end)
  end

  @impl Rung
  def label(_key), do: "troupe platform budget"

  # A deployment-wide total that was right a minute ago is exactly the kind of number that
  # lets a deployment quietly pass its own ceiling, so the two caps are read with it.
  @impl Rung
  def load(_key) do
    {bound_by, cap} =
      case ceiling() do
        :unlimited -> {nil, :unlimited}
        {scope, cap} -> {scope, cap}
      end

    %{
      ceiling: cap,
      bound_by: bound_by,
      spent_micros: Ledger.platform_totals().spent_micros,
      reservations: Ledger.open_reservations()
    }
  end

  @impl Rung
  def summary(_key, %{ceiling: cap, bound_by: bound_by}) do
    %{
      scope: :platform,
      budget_period: "monthly",
      bound_by: bound_by,
      budget_micros: if(cap == :unlimited, do: 0, else: cap)
    }
  end

  # What the deployment was given, and what a platform admin has said within it.
  defp ceiling do
    tightest(deployment: deployment_cap(), platform: platform_cap())
  end

  defp deployment_cap, do: Application.get_env(:troupe_plane, :deployment_budget_micros, 0)

  defp platform_cap, do: Settings.get("platform_budget_micros")
end
