import Config

# The CLI reaches a full-screen client through a behaviour rather than a compile-time
# dependency, so that `troupe_ctl` and `troupe_tui` both depend only on the protocol.
config :troupe_ctl, frontend: Troupe.TUI

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
