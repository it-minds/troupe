defmodule Troupe.Operator.Reconcilers do
  @moduledoc """
  One reconciler process per resource, started on demand.

  Watch events and the periodic resync both arrive as "here is a resource" — from
  different sources, possibly at the same time, possibly several for the same object.
  Routing them to a process named after the object means the work for one profile is
  serialised, and that process is somewhere to keep what reconciliation alone cannot
  see: how far a drain has got, whether an upgrade is waiting for one.

  It is not what makes reconciliation correct. That comes from being level-triggered:
  every pass reads the world, computes what should exist, and applies the difference,
  so two passes cannot produce two of anything. This is what keeps two passes from
  happening at once and wasting the work.
  """

  use Supervisor

  alias Troupe.Operator.Reconciler

  @registry Troupe.Operator.Reconciler.Registry
  @supervisor Troupe.Operator.Reconciler.Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Hand a resource to its own reconciler, and wait for the result.

  Synchronous, so a watch event and the resync cannot overlap on the same resource and
  a caller learns whether the pass succeeded.
  """
  @spec reconcile(K8s.Conn.t(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def reconcile(conn, resource, timeout \\ 120_000) do
    resource
    |> key()
    |> ensure_started(resource)
    |> GenServer.call({:reconcile, conn, resource}, timeout)
  end

  @doc "Stop a resource's reconciler, because the resource is gone."
  @spec forget(map()) :: :ok
  def forget(resource) do
    case Registry.lookup(@registry, key(resource)) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end

    :ok
  end

  @doc "Every reconciler currently running, for diagnostics."
  @spec list() :: [{term(), pid()}]
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  defp ensure_started(key, resource) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] ->
        pid

      [] ->
        spec = {Reconciler, key: key, name: via(key), kind: resource["kind"]}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> pid
          # Two events for the same resource arriving together is the ordinary case,
          # not a race to report.
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp key(resource) do
    {resource["kind"], get_in(resource, ["metadata", "namespace"]), get_in(resource, ["metadata", "name"])}
  end

  defp via(key), do: {:via, Registry, {@registry, key}}
end
