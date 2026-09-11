import Config

if config_env() == :prod do
  # Log to a file inside the state dir so raw-mode TUI output is never garbled.
  log_dir =
    System.get_env("TROUPE_STATE_DIR") ||
      Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "troupe")

  File.mkdir_p(log_dir)
  config :logger, :default_handler, config: [file: to_charlist(Path.join(log_dir, "troupe.log"))]
end
