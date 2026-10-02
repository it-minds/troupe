defmodule Troupe.Worker.Application do
  @moduledoc """
  The worker's supervision tree.

  Empty unless `:autostart` says otherwise, for the same reason the gateway's and the
  operator's are: the same umbrella compiles into a laptop binary and a test run, and
  booting either should not open a control connection to somebody's plane.

  In a pod it runs the link to the plane and the machinery that makes a session durable:
  sealing, uploading, and the disk watermarks that decide what may be cached.
  """

  use Application

  alias Troupe.Worker.Drain

  @impl Application
  def start(_type, _args) do
    children = if autostart?(), do: children(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Worker.Supervisor)
  end

  # Before any child goes down: a pod stopped by anything but the plane puts its sessions
  # to sleep first (`Drain.on_stop/1`). Only where the tree is a pod's; a laptop binary
  # and a test run hold no session of a plane's.
  @impl Application
  def prep_stop(state) do
    if autostart?(), do: Drain.on_stop()
    state
  end

  defp autostart?, do: Application.get_env(:troupe_worker, :autostart, false)

  # The MCP registry before the bundles, because a bundle hands its servers to the
  # registry; the bundles before the link, because the link's enrolment claims the
  # bundle hash the pod already has. `Connections` before the registry, because a
  # person-mode server discovered at start-up is one whose credentials may be asked for
  # on the first turn; `ClientCredentials` too, because discovering a server the profile
  # calls as itself takes its token. The MCP sessions the servers issue before all of
  # them, and stopped after them, which is when each is ended at its server (Decision 746).
  # The pod's OpenBao login first of all, since a session's key and a profile's signature
  # are both asked for with it (Decision 753).
  defp children do
    [
      Troupe.KMS.OpenBao.Login,
      Troupe.Worker.Sessions,
      Troupe.Worker.Auth,
      {Troupe.MCP.Sessions, name: Troupe.Worker.MCP.Sessions},
      Troupe.Worker.Connections,
      Troupe.Worker.ClientCredentials,
      Troupe.Worker.MCP,
      Troupe.Worker.Bundles,
      Troupe.Worker.Usage,
      Troupe.Worker.Disk.Watch
    ] ++ link() ++ [Troupe.Worker.Harness]
  end

  # A pod with no plane configured does not start the link. Retrying a Service name that
  # does not resolve, forever, is not resilience: it is a pod that cannot tell "the plane
  # is down" — which it must survive — from "there is no plane", which is a deployment
  # that was never finished.
  defp link do
    case Application.get_env(:troupe_worker, :plane) do
      nil -> []
      opts -> [{Troupe.Worker.Plane.Link, opts}]
    end
  end
end
