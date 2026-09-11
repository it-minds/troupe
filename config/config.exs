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

# Bonny reads a handful of things from application configuration rather than from the
# operator module. Only the name matters here — it labels the Kubernetes Events the
# operator records — because the CRDs are hand-written in the Helm chart and the
# connection is passed to the operator explicitly.
config :bonny,
  operator_name: "troupe-operator",
  service_account_name: "troupe-operator",
  group: "troupe.dev",
  versions: [Bonny.API.Version.V1]
