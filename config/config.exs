import Config

# The CLI reaches the terminal UI and the daemon through configuration rather than a
# compile-time dependency: `troupe_ctl` and `troupe_tui` may each depend only on the
# protocol, and the packaged binary is all three at once. Both are looked up at
# runtime, so a build that leaves one out simply has no such command.
config :troupe_ctl,
  frontend: Troupe.UI.TUI,
  fleet_view: Troupe.UI.HQ,
  daemon: Troupe.Gateway.Daemon

if Mix.env() == :test do
  # Tools that raise, exit, block on approval, or record their calls. Registered
  # through the same extension point a future MCP adapter would use.
  config :troupe_core, :extra_tools, [
    Troupe.Test.RaisingTool,
    Troupe.Test.ExitingTool,
    Troupe.Test.AskingTool,
    Troupe.Test.CountingTool
  ]
end
