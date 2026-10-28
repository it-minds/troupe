defmodule Troupe.Plane.Application do
  @moduledoc """
  The plane's supervision tree.

  Empty unless `:autostart` says otherwise. The same umbrella compiles into a laptop
  binary and into a test run, and booting either should not try to reach a database or
  join a cluster.

  In a cluster it runs the repository, `libcluster` to find the other replicas, the
  control listener workers dial, and the HTTP endpoint. The cluster-unique actors —
  one `Placement` per profile, one `TeamBudget` per team — are started on demand and
  registered with `:global`, so exactly one of each exists across every replica.
  """

  use Application

  alias Troupe.Plane.KMSCheck

  @impl Application
  def start(_type, _args) do
    children = if autostart?(), do: children(), else: []

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Plane.Supervisor) do
      # Once the tree is up, and apart from it: what the plane's OpenBao role lacks, a line
      # each in the log with the lines that grant it (`KMSCheck`). It never holds the
      # start up, and a check that fails takes nothing down with it.
      if autostart?(), do: Task.start(&KMSCheck.log/0)
      {:ok, pid}
    end
  end

  defp autostart?, do: Application.get_env(:troupe_plane, :autostart, false)

  defp children do
    [
      Troupe.Plane.Repo,
      # What an operator may change without a deploy, remembered for five seconds. Before
      # anything that reads a setting, which by the second line is everything.
      Troupe.Plane.Settings,
      # The plane's own, rather than a shared cluster topic: a drain waiting on a worker,
      # an invite changing, a laptop's offered session, each on one node's bus.
      {Phoenix.PubSub, name: Troupe.Plane.PubSub},
      # Where the cluster-unique actors live. One per node; the actors themselves are
      # registered with `:global`, so exactly one of each exists across all of them.
      Troupe.Plane.Singleton,
      Troupe.Plane.Fleet.Sweeper,
      # The in-plane cron is a `:global` singleton like the others, but nothing asks for
      # it the way a create asks for placement; the keeper asks, from every replica.
      Troupe.Plane.Triggers.Scheduler.Keeper,
      # The other half of `Placement`: the profile's replica count, asked for rather than
      # typed. Also a `:global` singleton nobody asks for on the happy path, so it gets a
      # keeper of its own for the same reason the scheduler does.
      Troupe.Plane.Fleet.Scaler.Keeper,
      # In GitOps mode, the pass that reads the cluster's resources into the rows everything
      # above places and scales by (Decision 736). A `:global` singleton with a keeper, for
      # the scaler's reasons; in direct mode each tick does nothing.
      Troupe.Plane.Gitops.Keeper,
      # Once as this replica starts: every profile whose image is `release` is written
      # again if the cluster carries anything but this release's worker image. On every
      # replica rather than as a singleton, which could be on a replica of the release being
      # replaced; `Fleet.ReleaseImage` says why that matters.
      Troupe.Plane.Fleet.ReleaseImage,
      {Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry},
      Troupe.Plane.Control.Connections,
      Troupe.Plane.Control.Listener,
      # Sums over an append-only table, remembered for a minute. Owned by a process so
      # that what it remembers dies with the node rather than outliving it.
      Troupe.Plane.Ledger.Cache,
      # The plane's OpenBao credential, exchanged once per lease rather than per token
      # minted. Before the endpoint, which is what mints them.
      Troupe.Plane.Tokens.Credential,
      # A private session's objects, deleted past the daemon's call when they take longer
      # than it waits (`Erasure.device_applied/2`, Decision 804). Before the endpoint,
      # which is where that call arrives.
      {Task.Supervisor, name: Troupe.Plane.Erasure.Tasks},
      # A GitHub delivery's work, done after the webhook has answered (`GitHub.Webhook`).
      # Before the endpoint, which is where deliveries arrive.
      {Task.Supervisor, name: Troupe.Plane.GitHub.Deliveries},
      # Every five minutes, the keys erasures have not yet destroyed, and at start the
      # team sessions' keys earlier releases left (Decision 811). A `:global` singleton
      # with a keeper, for the scheduler's reasons; after the credential it destroys with.
      Troupe.Plane.Erasure.Retry.Keeper,
      # A release being mirrored into the object store, copied after `admin.releases.mirror`
      # has answered (`Releases`), and which copies are under way. Before the endpoint,
      # which is where that call arrives.
      {Task.Supervisor, name: Troupe.Plane.Releases.Tasks},
      {Registry, keys: :unique, name: Troupe.Plane.Releases.Copies},
      Troupe.Plane.Web.Endpoint
    ] ++ artifacts() ++ cluster()
  end

  # The artifacts host (#62): its own listener on its own port, so nothing of the plane's
  # is ever answered on the origin where published pages run. None where the deployment
  # gave it no port.
  defp artifacts do
    case Keyword.get(Application.get_env(:troupe_plane, :artifacts, []), :port) do
      port when is_integer(port) ->
        [{Bandit, plug: Troupe.Plane.Web.Artifacts, scheme: :http, ip: {0, 0, 0, 0}, port: port}]

      _none ->
        []
    end
  end

  defp cluster do
    case Application.get_env(:troupe_plane, :topologies) do
      nil -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Troupe.Plane.ClusterSupervisor]]}]
    end
  end
end
