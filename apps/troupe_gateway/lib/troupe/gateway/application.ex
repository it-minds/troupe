defmodule Troupe.Gateway.Application do
  @moduledoc """
  The daemon's supervision tree.

  Started but idle unless `troupe_gateway`'s `:autostart` is set, because the same
  release is both the daemon and the clients that talk to it: a `troupe ctl` run must
  not open a listening socket just by booting.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:troupe_gateway, :autostart, false) do
        [Troupe.Gateway.Daemon]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Gateway.Supervisor)
  end
end
