# Boot the local daemon on this machine and keep it up until interrupted.
#
#     TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=scripts/daemon-spike.json \
#     mix run --no-halt scripts/daemon-spike.exs
#
# What this proves is the shape the daemon release will have: `troupe_core` and
# `troupe_gateway` started with the gateway's `Daemon` supervisor, no plane, no worker
# link, the loopback WebSocket published in `daemon.json` so a graphical client can find
# it. Nothing here is packaging; `scripts/daemon-spike.mjs` is the client side.
#
# `TROUPE_STATE_HOME`, `XDG_RUNTIME_DIR` and `LOCALAPPDATA` are honoured, so a run can be
# pointed at a scratch directory rather than the developer's real state.

alias Troupe.Protocol.Endpoint

endpoint =
  case System.get_env("TROUPE_SPIKE_ENDPOINT", "unix") do
    "tcp" -> Endpoint.tcp()
    _ -> Endpoint.default()
  end

{:ok, _pid} =
  Troupe.Gateway.Daemon.start_link(
    endpoint: endpoint,
    idle_shutdown_ms: :timer.hours(24),
    loopback: [enabled: true]
  )

IO.puts("daemon: #{Endpoint.describe(endpoint)}")
IO.puts("discovery: #{Endpoint.discovery_path()}")
IO.puts(File.read!(Endpoint.discovery_path()))
IO.puts("state: #{Troupe.Paths.state_dir()}")
IO.puts("provider: #{System.get_env("TROUPE_PROVIDER", "anthropic")}")

# The daemon is linked to this script's process, and a supervisor whose parent exits
# shuts down with it — taking `daemon.json` away as it goes. So the script never
# returns; the release will own the daemon in its own supervision tree instead.
Process.sleep(:infinity)
