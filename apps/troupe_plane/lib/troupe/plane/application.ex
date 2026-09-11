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
      # Where the cluster-unique actors live. One per node; the actors themselves are
      # registered with `:global`, so exactly one of each exists across all of them.
      Troupe.Plane.Singleton,
      Troupe.Plane.Fleet.Sweeper,
      {Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry},
      Troupe.Plane.Control.Connections,
      Troupe.Plane.Control.Listener
    ] ++ cluster()
  end

  defp cluster do
    case Application.get_env(:troupe_plane, :topologies) do
      nil -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Troupe.Plane.ClusterSupervisor]]}]
    end
  end
end
