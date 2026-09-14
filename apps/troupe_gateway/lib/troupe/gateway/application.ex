defmodule Troupe.Gateway.Application do
  @moduledoc """
  The daemon's supervision tree.

  Started but idle unless `troupe_gateway`'s `:autostart` is set. Booting this
  application must not open a listening socket on its own: the same code runs inside a
  worker pod, which is told to serve, and inside a test or an embedding host, which is
  not.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:troupe_gateway, :autostart, false) do
        # A real daemon serves a person, and a person may be looking at a graphical
        # client, which has no way to reach a Unix socket or a raw TCP one.
        [{Troupe.Gateway.Daemon, loopback: [enabled: true]}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Gateway.Supervisor)
  end
end
