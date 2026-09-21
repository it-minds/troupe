import Config

# No test may put anything on the developer's real clipboard, so copying goes to
# a sink unless a test points `clipboard_command` at a file of its own.
config :troupe, clipboard_command: "cat > /dev/null"
