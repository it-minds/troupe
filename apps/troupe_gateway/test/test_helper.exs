# A config directory of the suite's own, rather than the developer's: tests put the
# scripted model in a scratch workspace's `.troupe/config.yaml`, which a project's file
# sets only in a trusted workspace, and the scratch workspaces are made under the
# system's temp directory. A test that needs another config directory sets its own.
config_home =
  Path.join(System.tmp_dir!(), "troupe-gateway-test-config-#{System.unique_integer([:positive])}")

File.mkdir_p!(config_home)
System.put_env("TROUPE_CONFIG_HOME", config_home)

File.write!(
  Path.join(config_home, "config.yaml"),
  "version: 1\ntrusted_workspaces:\n  - #{Jason.encode!(System.tmp_dir!())}\n"
)

System.at_exit(fn _ -> File.rm_rf!(config_home) end)

ExUnit.start()
