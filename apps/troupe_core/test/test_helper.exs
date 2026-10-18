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

# The organisation's layer (Decision 869) is read from a managed file at a fixed path and
# from the state directory: a test run reads neither of this machine's, but two of its
# own that are not there until a test writes them.
Application.put_env(:troupe_core, :organisation,
  managed_path: Path.join(config_home, "org/managed.yaml"),
  cache_path: Path.join(config_home, "org/organisation.json"),
  keys_path: Path.join(config_home, "org/plane-keys.json")
)

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
# look like failures. The level is the VM's, though, and one `mix test` naming files of
# core and of another app runs both suites in one VM, so it is put back as core's suite
# ends: the next app's `capture_log` hears what that app logs.
level = Logger.level()
Logger.configure(level: :critical)
ExUnit.after_suite(fn _result -> Logger.configure(level: level) end)

# Loaded now rather than by the first test to call each one, which then waits on the read
# behind every other test's: on a slow disk that wait is past the suite's timeouts.
Code.require_file("support/preload.exs", __DIR__)
Troupe.Test.Preload.run()

ExUnit.start(capture_log: true)
