# Every session in this suite runs in a daemon this VM embeds, and the daemon reads the
# machine's configuration. So the machine, for the duration of the run, is a scratch
# directory: state (session logs, daemon.json) and config live there, no provider is
# inherited from the environment, and no opencode installation is found.
tmp = Path.join(System.tmp_dir!(), "troupe-tui-test-#{System.system_time(:millisecond)}")
File.mkdir_p!(Path.join(tmp, "state"))
File.mkdir_p!(Path.join(tmp, "config"))
File.mkdir_p!(Path.join(tmp, "run"))
System.put_env("TROUPE_STATE_HOME", Path.join(tmp, "state"))
System.put_env("TROUPE_CONFIG_HOME", Path.join(tmp, "config"))
System.put_env("XDG_RUNTIME_DIR", Path.join(tmp, "run"))
System.put_env("LOCALAPPDATA", Path.join(tmp, "run"))
System.delete_env("TROUPE_DAEMON_SOCKET")
System.delete_env("TROUPE_DAEMON_COMMAND")

for var <-
      ~w(TROUPE_PROVIDER TROUPE_MODEL TROUPE_API_KEY TROUPE_BASE_URL TROUPE_AUTH TROUPE_AUTH_TOKEN TROUPE_FAKE_SCRIPT ANTHROPIC_API_KEY OPENAI_API_KEY) do
  System.delete_env(var)
end

System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(tmp, "no-opencode.jsonc"))
System.put_env("TROUPE_OPENCODE_AUTH", Path.join(tmp, "no-auth.json"))

ExUnit.start(exclude: [:manual, :slow], timeout: 60_000, capture_log: true)
