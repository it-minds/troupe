import Config

if Mix.env() == :test do
  # Tools that raise, exit, block on approval, or record their calls. Registered
  # through the same extension point a future MCP adapter would use.
  config :troupe_core, :extra_tools, [
    Troupe.Test.RaisingTool,
    Troupe.Test.ExitingTool,
    Troupe.Test.AskingTool,
    Troupe.Test.CountingTool
  ]

  # No session a test starts asks its provider for the model list (Decision 778): many
  # carry a key and no base URL, which is a real provider's own endpoint. A test of the
  # refresh turns it on and points it at a stand-in.
  config :troupe_core, catalog_refresh: false

  # Nothing a test does reaches the person's own credential store (#58): the daemon's sign-in
  # for steering is kept in the VM. `Troupe.KeyringTest` asks the real one, by a test name.
  config :troupe_protocol, keyring: Troupe.Keyring.Memory
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

# The panel and the API are served from one endpoint. `server: false` by default for the
# same reason `autostart` is: the same umbrella compiles into a laptop binary, and
# booting it should not open a port.
config :troupe_plane, Troupe.Plane.Web.Endpoint,
  # Bandit rather than Phoenix's default Cowboy: the control listener and the daemon are
  # already plain `:gen_tcp` and Bandit is the one that does not bring a second HTTP
  # implementation into the release for the sake of one endpoint.
  adapter: Bandit.PhoenixAdapter,
  server: false,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  # Overridden at boot in a cluster. A default exists so a test or a laptop can start the
  # endpoint without one; a production release that used it would be signing cookies with
  # a value printed in this repository, which `runtime.exs` refuses to let happen.
  secret_key_base: String.duplicate("troupe-development-secret-not-for-a-cluster", 3),
  live_view: [signing_salt: "troupe-plane-live"],
  pubsub_server: Troupe.Plane.PubSub,
  render_errors: [formats: [html: Troupe.Plane.Web.ErrorHTML], layout: false]

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
    port: 25_432,
    database: "troupe_plane_#{Mix.env()}",
    pool_size: 10

  if Mix.env() == :test do
    # A test database per checkout: two checkouts' suites on one database lock the same
    # rows from two sandboxes and deadlock (Postgres `40P01`). The name carries a hash of
    # the checkout's path, and the suite creates and migrates it
    # (`apps/troupe_plane/test/support/test_database.exs`). CI has one checkout and keeps
    # the plain name; `TROUPE_PLANE_TEST_DB` names one outright.
    checkout = Path.expand("..", __DIR__)

    test_database =
      System.get_env("TROUPE_PLANE_TEST_DB") ||
        if(System.get_env("CI") in [nil, "", "false"],
          do:
            "troupe_plane_test_#{checkout |> :erlang.phash2() |> Integer.to_string(36) |> String.downcase()}",
          else: "troupe_plane_test"
        )

    # A pool big enough for the concurrency the tests actually exercise: the placement
    # test makes fifty creates at once, which is the point of it, and a pool of ten
    # would be measuring the pool rather than the actor.
    config :troupe_plane, Troupe.Plane.Repo,
      database: test_database,
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
  config :troupe_protocol,
    object_store: [
      endpoint: "http://localhost:29000",
      bucket: "troupe-sessions",
      access_key_id: "troupe",
      secret_access_key: "troupe-secret",
      region: "us-east-1"
    ]

  config :troupe_worker,
    kms: [
      address: "http://localhost:28200",
      token: "troupe-dev-root",
      mount: "secret"
    ]

  # The plane signs against the same development OpenBao, with the same root token. Set
  # here, for these two environments only, because `Troupe.Plane.Tokens` has no default
  # of its own: a production plane that has not been given a credential must fail to
  # sign rather than try the development root token against a real cluster.
  config :troupe_plane,
    transit: [
      address: "http://localhost:28200",
      token: "troupe-dev-root"
    ]
end
