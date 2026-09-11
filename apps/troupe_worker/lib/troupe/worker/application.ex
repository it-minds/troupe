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

  @impl Application
  def start(_type, _args) do
    children = if autostart?(), do: children(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Worker.Supervisor)
  end

  defp autostart?, do: Application.get_env(:troupe_worker, :autostart, false)

  defp children do
    [
      Troupe.Worker.Sessions,
      Troupe.Worker.Auth,
      Troupe.Worker.Disk.Watch,
      Troupe.Worker.Plane.Link,
      Troupe.Worker.Harness
    ]
  end
end
