# One empty config directory for the whole suite. Set once here rather than per test:
# `System.put_env/2` is process-global, so a per-test value would leak across the
# `async: true` suite. Per-test *state* isolation goes through config instead.
config_home =
  Path.join(System.tmp_dir!(), "troupe-test-config-#{System.unique_integer([:positive])}")

File.mkdir_p!(config_home)
System.put_env("TROUPE_CONFIG_HOME", config_home)

# Tests put a provider, MCP servers and read roots in a scratch workspace's own
# `.troupe/config.yaml`, which a project's file sets only in a trusted workspace. The
# scratch workspaces are made under the system's temp directory, so that is trusted; a
# test about the trust gate itself reads a user file of its own (`user_path:`).
File.write!(
  Path.join(config_home, "config.yaml"),
  "version: 1\ntrusted_workspaces:\n  - #{Jason.encode!(System.tmp_dir!())}\n"
)
System.delete_env("TROUPE_STATE_HOME")
System.at_exit(fn _ -> File.rm_rf!(config_home) end)

# The person's own `~/.agents/skills` (Decision 822) is read from the home directory,
# which a test cannot move: an empty one of the suite's own instead of the developer's.
Application.put_env(:troupe_core, :agents_home, Path.join(config_home, "home/.agents"))

# Starting the daemon at login (Decision 762) writes into the person's own login items:
# here into a scratch home instead, for every test that reaches it through the first
# run's questions, starting a `troupe-daemon` that need not exist.
login_home =
  Path.join(System.tmp_dir!(), "troupe-test-login-#{System.unique_integer([:positive])}")

Application.put_env(:troupe_core, :start_at_login,
  env: %{
    "HOME" => login_home,
    "APPDATA" => Path.join(login_home, "AppData"),
    "XDG_CONFIG_HOME" => Path.join(login_home, ".config")
  },
  command: "/opt/troupe/bin/troupe-daemon"
)

System.at_exit(fn _ -> File.rm_rf!(login_home) end)

# Logger output is noise here: the suite asserts on events and telemetry, never on
# log lines, and the crashing-agent tests would otherwise print stacktraces that
# look like failures.
Logger.configure(level: :critical)

ExUnit.start(capture_log: true)
