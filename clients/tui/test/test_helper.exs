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

# The tests drive the daemon's scripted model from each workspace's `.troupe/config.yaml`
# (`provider: fake`, `fake_script:`), and a project's file sets those only in a trusted
# workspace. Every test workspace, and every worktree made beside one, is under the
# system's temp directory, so the machine's user file trusts that.
File.write!(
  Path.join([tmp, "config", "config.yaml"]),
  "version: 1\ntrusted_workspaces:\n  - #{Jason.encode!(System.tmp_dir!())}\n"
)

# The setup's screen reaches the daemon's `daemon` step (TUI Decision 153), which writes or
# removes the person's own login entry (root Decision 762): here a scratch home's, with a
# `troupe-daemon` that need not exist, as the core and gateway suites do.
Application.put_env(:troupe_core, :start_at_login,
  env: %{
    "HOME" => Path.join(tmp, "login"),
    "APPDATA" => Path.join([tmp, "login", "AppData"]),
    "XDG_CONFIG_HOME" => Path.join([tmp, "login", ".config"])
  },
  command: "/opt/troupe/bin/troupe-daemon"
)

ExUnit.start(exclude: [:manual, :slow], timeout: 60_000, capture_log: true)
