import Config

if config_env() == :prod do
  # Log to a file so raw-mode TUI output is never garbled: `troupe.log` in the state
  # directory, beside the daemon's `daemon.log`, found the way the daemon finds it
  # (`Troupe.Paths.state_dir/0`): `TROUPE_STATE_HOME`, else `$XDG_STATE_HOME/troupe` or
  # `%LOCALAPPDATA%\troupe`. A daemon this process embeds logs here too.
  log_dir = Troupe.Paths.state_dir()

  File.mkdir_p(log_dir)
  config :logger, :default_handler, config: [file: to_charlist(Path.join(log_dir, "troupe.log"))]
end
