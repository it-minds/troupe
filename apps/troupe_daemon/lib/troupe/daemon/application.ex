defmodule Troupe.Daemon.Application do
  @moduledoc """
  The daemon's own supervision tree: `Troupe.Gateway.Daemon`, when this VM is here to serve.

  `troupe_core`, `troupe_gateway` and `troupe_protocol` are already up when this starts —
  the release lists them as permanent applications — and none of them has opened a
  socket, because the gateway's `autostart` is off. This application is what opens one:
  `bin/troupe_daemon start` boots the release, the release boots this, and this starts the
  daemon with the loopback WebSocket on, so a graphical client has a door too.

  Under `mix test`, `mix run` or `bin/troupe_daemon eval` nothing is started: a test that
  wants a daemon asks for one, and `eval` — which is how `troupe-daemon status` and its
  siblings run — must be able to load this code on a machine where a daemon is already
  listening. `TROUPE_DAEMON_SERVE=1` starts it under `mix run` on purpose.
  """

  use Application

  alias Troupe.Daemon.CLI

  @impl Application
  def start(_type, _args) do
    children = if serve?(), do: [{Troupe.Gateway.Daemon, CLI.run_opts()}, announcer()], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Daemon.Supervisor)
  end

  # A release booted with `start`, and nothing else. `eval` sets `RELEASE_NAME` too but
  # boots `start_clean`, which starts no application of ours — so this is never reached
  # from there.
  defp serve? do
    System.get_env("RELEASE_NAME") != nil or System.get_env("TROUPE_DAEMON_SERVE") == "1"
  end

  # Say where the daemon is listening, once, after it is. `:temporary`: a line that was
  # printed is not a crash to restart.
  defp announcer do
    %{id: :announce, start: {Task, :start_link, [&CLI.announce/0]}, restart: :temporary}
  end
end
