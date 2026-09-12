defmodule Troupe.A2A.Application do
  @moduledoc """
  The facade's supervision tree.

  The token cache and the stream counter always start: neither opens a port, and a
  test drives the router against them directly. The listener starts only when
  `:autostart` says so, for the same reason the plane's does — the umbrella compiles
  into more than one thing, and booting the others should not bind a port.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [
        Troupe.A2A.Plane.Cache,
        Troupe.A2A.Streams
      ] ++ listener()

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.A2A.Supervisor)
  end

  defp listener do
    if Troupe.A2A.autostart?() do
      [{Bandit, plug: Troupe.A2A.Router, scheme: :http, port: Troupe.A2A.port(), ip: :any}]
    else
      []
    end
  end
end
