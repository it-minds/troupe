defmodule Troupe.Operator.Descendants do
  @moduledoc """
  Watches what the operator created, so that removing one puts it back.

  The periodic resync would eventually notice — that is what a resync is for — but
  "eventually" is a minute of a profile's pods being unreachable because somebody
  deleted an Ingress. Watching the objects themselves turns that into a reconcile that
  starts as the deletion lands.

  One watch per kind the operator creates, across all namespaces, filtered to the
  operator's own marker. A deletion is mapped back to its profile by label, the profile
  is read, and its reconciler runs a normal pass — the same pass a watch event on the
  profile would have run, because reconciliation is level-triggered and does not care
  what prompted it.
  """

  use Supervisor

  alias Bonny.Server.{AsyncStreamRunner, Watcher}
  alias Troupe.Operator.{Names, Reconcilers}

  require Logger

  @kinds [
    {"v1", "Service"},
    {"v1", "ServiceAccount"},
    {"apps/v1", "StatefulSet"},
    {"networking.k8s.io/v1", "Ingress"},
    {"networking.k8s.io/v1", "NetworkPolicy"},
    {"policy/v1", "PodDisruptionBudget"}
  ]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    namespace = Keyword.fetch!(opts, :namespace)

    children =
      Enum.map(@kinds, fn {api_version, kind} = gvk ->
        Supervisor.child_spec(
          {AsyncStreamRunner,
           id: {__MODULE__, kind},
           stream: stream(conn, gvk, namespace),
           # A watch stream ends when the API server rotates it. Restarting promptly is
           # the normal case, not a failure to back off from.
           termination_delay: 1_000},
          id: {__MODULE__, api_version, kind}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 20, max_seconds: 60)
  end

  defp stream(conn, {api_version, kind}, profile_namespace) do
    operation =
      api_version
      |> K8s.Client.watch(kind, namespace: :all)
      |> K8s.Operation.put_selector(K8s.Selector.label({Names.managed_label(), "operator"}))

    conn
    |> Watcher.get_raw_stream(operation)
    |> Stream.filter(&match?({:deleted, _}, &1))
    |> Stream.each(&repair(conn, &1, profile_namespace))
  end

  defp repair(conn, {:deleted, resource}, profile_namespace) do
    case get_in(resource, ["metadata", "labels", "troupe.dev/profile"]) do
      nil ->
        :ok

      profile ->
        Logger.info(
          "troupe operator: #{resource["kind"]}/#{get_in(resource, ["metadata", "name"])} was " <>
            "deleted, reconciling #{profile}"
        )

        reconcile_profile(conn, profile, profile_namespace)
    end
  end

  # A profile that is itself being deleted takes its namespace with it, and every
  # object in it is deleted too. Reading the profile first is what keeps those
  # deletions from being put back one at a time.
  defp reconcile_profile(conn, profile, namespace) do
    operation = K8s.Client.get("troupe.dev/v1alpha1", "WorkerProfile", namespace: namespace, name: profile)

    case K8s.Client.run(conn, operation) do
      {:ok, resource} -> Reconcilers.reconcile(conn, resource)
      {:error, _reason} -> :ok
    end
  end
end
