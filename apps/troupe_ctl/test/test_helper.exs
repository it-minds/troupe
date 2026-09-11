# One empty config directory for the whole suite. Set once here rather than per test:
# `System.put_env/2` is process-global, so a per-test value would leak across the
# `async: true` suite. Per-test *state* isolation goes through config instead.
config_home =
  Path.join(System.tmp_dir!(), "troupe-test-config-#{System.unique_integer([:positive])}")

File.mkdir_p!(config_home)
System.put_env("TROUPE_CONFIG_HOME", config_home)
System.delete_env("TROUPE_STATE_HOME")
System.at_exit(fn _ -> File.rm_rf!(config_home) end)

# Logger output is noise here: the suite asserts on events and telemetry, never on
# log lines, and the crashing-agent tests would otherwise print stacktraces that
# look like failures.
Logger.configure(level: if(System.get_env("TROUPE_TEST_LOGS"), do: :debug, else: :critical))

ExUnit.start(capture_log: System.get_env("TROUPE_TEST_LOGS") == nil)
