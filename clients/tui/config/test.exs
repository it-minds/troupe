import Config

# No test may put anything on the developer's real clipboard, so copying goes to
# a sink unless a test points `clipboard_command` at a file of its own.
config :troupe, clipboard_command: "cat > /dev/null"

# Nor may a session it starts ask a provider for its model list in the background (root
# Decision 778): `troupe models`, which asks in the foreground, is tested against a stand-in.
config :troupe_core, catalog_refresh: false
