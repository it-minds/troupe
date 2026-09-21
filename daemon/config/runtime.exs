import Config

# Read at boot, in the release and under `mix run` alike. Nothing here turns an
# environment value into an atom by lookup (troupe-remote Decision 634): a value is
# compared against the strings it may be, and anything else is refused with a message
# that names the variable, so `bin/troupe_daemon eval` works on a machine whose
# environment is not the daemon's.

# -- where the daemon writes ------------------------------------------------------------

# A daemon started by a client is detached from any terminal, so its log goes to a file
# under the state directory beside the sessions it is about. `TROUPE_DAEMON_LOG=stderr`
# keeps it on the console, which is what a developer running it by hand wants.
log =
  case System.get_env("TROUPE_DAEMON_LOG", "file") do
    "file" -> :file
    "stderr" -> :stderr
    other -> raise "TROUPE_DAEMON_LOG is #{inspect(other)}; expected file or stderr"
  end

if log == :file and System.get_env("RELEASE_NAME") do
  dir = Troupe.Paths.state_dir()
  File.mkdir_p!(dir)

  config :logger, :default_handler,
    config: [
      file: String.to_charlist(Path.join(dir, "daemon.log")),
      max_no_bytes: 5_000_000,
      max_no_files: 3
    ]
end

level =
  case System.get_env("TROUPE_LOG_LEVEL", "info") do
    "debug" -> :debug
    "info" -> :info
    "warning" -> :warning
    "error" -> :error
    other -> raise "TROUPE_LOG_LEVEL is #{inspect(other)}; expected debug, info, warning or error"
  end

config :logger, level: level

# -- how long it stays up -----------------------------------------------------------------

# Minutes with no client attached and no session running before the daemon exits.
# `0` means never, for a machine that wants it resident.
idle =
  case Integer.parse(System.get_env("TROUPE_DAEMON_IDLE_MINUTES", "10")) do
    {0, ""} -> :timer.hours(24 * 365)
    {minutes, ""} when minutes > 0 -> :timer.minutes(minutes)
    _ -> raise "TROUPE_DAEMON_IDLE_MINUTES is not a whole number of minutes"
  end

config :troupe_daemon, idle_shutdown_ms: idle
