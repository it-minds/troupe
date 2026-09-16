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

  @impl Application
  def start(_type, _args) do
    children = if autostart?(), do: children(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Plane.Supervisor)
  end

  defp autostart?, do: Application.get_env(:troupe_plane, :autostart, false)

  defp children do
    [
      Troupe.Plane.Repo,
      # What an operator may change without a deploy, remembered for five seconds. Before
      # anything that reads a setting, which by the second line is everything.
      Troupe.Plane.Settings,
      # LiveView needs one, and it is the plane's own rather than a shared cluster topic:
      # what it carries is one browser's view of one page.
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
      {Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry},
      Troupe.Plane.Control.Connections,
      Troupe.Plane.Control.Listener,
      # Sums over an append-only table, remembered for a minute. Owned by a process so
      # that what it remembers dies with the node rather than outliving it.
      Troupe.Plane.Ledger.Cache,
      # The plane's OpenBao credential, exchanged once per lease rather than per token
      # minted. Before the endpoint, which is what mints them.
      Troupe.Plane.Tokens.Credential,
      Troupe.Plane.Web.Endpoint
    ] ++ cluster()
  end

  defp cluster do
    case Application.get_env(:troupe_plane, :topologies) do
      nil -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Troupe.Plane.ClusterSupervisor]]}]
    end
  end
end
