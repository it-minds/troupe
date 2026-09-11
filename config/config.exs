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

config :troupe_plane,
  ecto_repos: [Troupe.Plane.Repo],
  # Started only where a plane is meant to run. The same umbrella compiles into a
  # laptop binary, and booting it should not try to reach a database.
  autostart: false

config :troupe_plane, Troupe.Plane.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

if Mix.env() in [:dev, :test] do
  # `scripts/dev-up` brings this up on a port of its own, so a machine that already
  # runs a Postgres does not notice.
  config :troupe_plane, Troupe.Plane.Repo,
    username: "troupe",
    password: "troupe",
    hostname: "localhost",
    port: 55_432,
    database: "troupe_plane_#{Mix.env()}",
    pool_size: 10

  if Mix.env() == :test do
    # A pool big enough for the concurrency the tests actually exercise: the placement
    # test makes fifty creates at once, which is the point of it, and a pool of ten
    # would be measuring the pool rather than the actor.
    config :troupe_plane, Troupe.Plane.Repo,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 30,
      queue_target: 5_000,
      queue_interval: 10_000
  end
end

config :troupe_worker, autostart: false

if Mix.env() in [:dev, :test] do
  # `scripts/dev-up` brings these up on ports of their own, so a machine that already
  # runs a MinIO or an OpenBao does not notice.
  config :troupe_worker,
    object_store: [
      endpoint: "http://localhost:59000",
      bucket: "troupe-sessions",
      access_key_id: "troupe",
      secret_access_key: "troupe-secret",
      region: "us-east-1"
    ],
    kms: [
      address: "http://localhost:58200",
      token: "troupe-dev-root",
      mount: "secret"
    ]
end
