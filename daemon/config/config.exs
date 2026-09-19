import Config

# The gateway must not open a socket on its own: `Troupe.Daemon.Application` starts the
# daemon when — and only when — the binary was invoked to run one. A test, `mix run` or
# a `troupe-daemon status` boots the same applications and listens on nothing.
config :troupe_gateway, autostart: false

if Mix.env() == :test do
  config :logger, level: :warning
end
