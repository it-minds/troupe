defmodule Troupe.Operator.Supervisor do
  @moduledoc """
  What the operator runs when it is actually operating.

  `rest_for_one`: the reconcilers come first, because everything after them feeds them
  and a watch delivering to processes that are not there yet would drop the event. The
  connection to the API server is built here, once, and handed down — a client rebuilt
  per reconcile would re-read its token file every pass.

  Two sources of work. `Watch` is Bonny's: the watch on `WorkerProfile` and
  `TeamVolume`, the periodic resync, and leader election through a Kubernetes `Lease`.
  `Descendants` watches the objects the operator created, so deleting one starts a
  reconcile immediately rather than at the next resync.
  """

  use Supervisor

  alias Troupe.Operator.{Conn, Descendants, Reconcilers, Watch}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    Process.set_label("troupe operator")
    {:ok, conn} = Conn.get()

    namespace = Keyword.get(opts, :namespace, watch_namespace())

    children = [
      {Reconcilers, opts},
      {Watch,
       [
         conn: conn,
         watch_namespace: namespace,
         enable_leader_election: Keyword.get(opts, :leader_election, true)
       ]},
      {Descendants, conn: conn, namespace: namespace}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end

  defp watch_namespace, do: System.get_env("TROUPE_PLANE_NAMESPACE") || "troupe-system"
end
