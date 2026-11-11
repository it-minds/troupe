import Config

# No test may put anything on the developer's real clipboard, so copying goes to
# a sink unless a test points `clipboard_command` at a file of its own.
config :troupe, clipboard_command: "cat > /dev/null"

# Nor may a session it starts ask a provider for its model list in the background (root
# Decision 778): `troupe models`, which asks in the foreground, is tested against a stand-in.
config :troupe_core, catalog_refresh: false

# Nor reach the person's own credential store (root #58): a daemon a test embeds keeps its
# sign-in for steering in the VM.
config :troupe_protocol, keyring: Troupe.Keyring.Memory

# Nor read the directories of skills other tools keep in the developer's home
# (`skills.discover`): a test names the home it means.
config :troupe_core, skills_home: Path.join(System.tmp_dir!(), "troupe-test-no-home")
