defmodule Troupe.Plane.PlatformBudget do
  @moduledoc """
  The two ceilings above every team: what the deployment allows, and what a platform
  admin allows within that.

  One actor, one key, because both ceilings are over the same number — everything this
  plane has spent and promised, across every team. Two actors for two caps on one total
  would be two answers to one question.

  ## A stored ceiling may only narrow

  The deployment's cap comes from a Helm value and is the floor of the argument: an
  operator who could raise it from inside the console could raise it past whatever the
  people paying for this agreed to. So a platform admin's cap applies when it is
  *tighter* and is ignored when it is not — the ladder's rule, a lower rung may only
  narrow, made concrete in the one place it is about money.

  The refusal names which of the two bound, because "over budget" without a scope is a
  support ticket and "the platform cap, which is tighter than the deployment's" is an
  instruction.
  """

  use GenServer

  alias Troupe.Plane.{Ledger, Settings, Singleton}

  # One of a kind: there is one platform.
  @key :platform

  defstruct reservations: %{}, spent_micros: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Whether this deployment can promise `amount_micros` more.

  Decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed — a row written by the first rung
  would be counted by the rungs after it as though somebody else had made it.
  """
  @spec reserve(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(session_id, amount_micros) do
    Singleton.call(__MODULE__, @key, {:reserve, session_id, amount_micros})
  end

  @doc "Give a promise back."
  @spec release(String.t()) :: :ok
  def release(session_id), do: Singleton.call(__MODULE__, @key, {:release, session_id})

  @doc "Both ceilings, which one binds, and how much of it is gone."
  @spec inspect_state() :: map()
  def inspect_state, do: Singleton.call(__MODULE__, @key, :inspect)

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

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe platform budget")
    {:ok, %__MODULE__{}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl GenServer
  def handle_call({:reserve, session_id, amount}, _from, state) do
    state = load(state)

    cond do
      Map.has_key?(state.reservations, session_id) ->
        {:reply, {:ok, summary(state)}, state}

      fits?(state, amount) ->
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

  # Re-read on every decision. This is asked once per session create, which is not a hot
  # path, and a deployment-wide total that was right a minute ago is exactly the kind of
  # number that lets a deployment quietly pass its own ceiling.
  #
  # Reservations the ledger knows about are merged *under* what this actor is holding, so
  # a session granted a moment ago and not yet written is counted once rather than twice.
  defp load(state) do
    totals = Ledger.platform_totals()
    known = Ledger.open_reservations()

    %{
      state
      | spent_micros: totals.spent_micros,
        reservations: Map.merge(known, state.reservations)
    }
  end

  defp fits?(state, amount) do
    case ceiling() do
      :unlimited -> true
      {_scope, cap} -> state.spent_micros + reserved(state) + amount <= cap
    end
  end

  defp reserved(state), do: state.reservations |> Map.values() |> Enum.sum()

  # What the deployment was given, and what a platform admin has said within it.
  defp ceiling do
    tightest(deployment: deployment_cap(), platform: platform_cap())
  end

  defp deployment_cap, do: Application.get_env(:troupe_plane, :deployment_budget_micros, 0)

  defp platform_cap, do: Settings.get("platform_budget_micros")

  defp summary(state) do
    base = %{
      scope: :platform,
      spent_micros: state.spent_micros,
      reserved_micros: reserved(state),
      node: node()
    }

    case ceiling() do
      :unlimited ->
        Map.merge(base, %{bound_by: nil, budget_micros: 0, remaining_micros: :unlimited})

      {scope, cap} ->
        Map.merge(base, %{
          bound_by: scope,
          budget_micros: cap,
          remaining_micros: max(cap - state.spent_micros - reserved(state), 0)
        })
    end
  end
end
