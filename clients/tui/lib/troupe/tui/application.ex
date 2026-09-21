defmodule Troupe.TUI.Application do
  @moduledoc """
  The client's supervision tree: what a terminal in front of a daemon needs, and nothing
  that runs an agent.

  `troupe_core`, `troupe_gateway` and `troupe_protocol` are dependencies and start first;
  the gateway's `autostart` is off, so booting this opens no socket. `Troupe.Client.Daemon`
  starts an embedded daemon under `Troupe.Client.Daemons` the first time a local session
  is wanted and nothing on this machine answers — the same `Troupe.Gateway.Daemon` the
  `troupe-daemon` binary runs — or attaches to the one that does. Either way the TUI is a
  client of it through the protocol, and `mix troupe.xref` holds the UI to `Troupe.Client`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Troupe.Client.Registry},
      {Registry, keys: :duplicate, name: Troupe.Client.Events},
      {DynamicSupervisor, name: Troupe.Client.Daemons, strategy: :one_for_one},
      Troupe.Client.Daemon.Link,
      Troupe.Remote.Supervisor,
      Troupe.UI.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.TUI.Supervisor)
  end
end
