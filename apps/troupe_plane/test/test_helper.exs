alias Ecto.Adapters.SQL.Sandbox
alias Troupe.Plane.Repo

default_kubeconfig = fn ->
  case System.fetch_env("HOME") || System.fetch_env("USERPROFILE") do
    {:ok, home} -> Path.join(home, ".kube/config")
    :error -> nil
  end
end

# The panel's tests drive a real endpoint, so it has to be listening — on port 0, because
# a test suite that claimed a fixed port would fail on a machine already running a plane.
Application.put_env(:troupe_plane, Troupe.Plane.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: String.duplicate("troupe-test-secret-key-base-padding", 3),
  live_view: [signing_salt: "troupe-plane-test"],
  pubsub_server: Troupe.Plane.PubSub,
  render_errors: [formats: [html: Troupe.Plane.Web.ErrorHTML], layout: false]
)

# Enrolment is a `TokenReview`, so the `:cluster` tests need a real API server. Without
# one they are excluded rather than failed — the same bargain the database gets below,
# and for the same reason: a suite that is red on every machine without a cluster is a
# suite nobody reads. `--include cluster` overrides it.
cluster =
  with path when is_binary(path) <- System.get_env("KUBECONFIG") || default_kubeconfig.(),
       true <- File.exists?(path),
       {:ok, conn} <- K8s.Conn.from_file(path, context: System.get_env("TROUPE_KUBE_CONTEXT")),
       {:ok, _} <- K8s.Client.run(conn, K8s.Client.list("v1", "Namespace")) do
    :ok
  else
    false -> {:error, :no_kubeconfig}
    nil -> {:error, :no_kubeconfig}
    {:error, reason} -> {:error, reason}
  end

without_cluster =
  case cluster do
    :ok ->
      []

    {:error, reason} ->
      IO.puts(:stderr, """

      SKIPPED: no Kubernetes cluster (#{inspect(reason)}).
      Enrolment is a TokenReview, so the `:cluster` tests need a real API server and
      did not run. Bring one up with `scripts/kind-up`.
      """)

      [:cluster]
  end

# The plane is the one app in the umbrella that needs a database. Without one its tests
# are skipped — loudly, with the command that brings it up — rather than failing in a way
# that looks like a bug in the code.
case Repo.start_link(pool: Sandbox) do
  {:ok, _pid} ->
    Sandbox.mode(Repo, :manual)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Troupe.Plane.PubSub)
    {:ok, _} = Troupe.Plane.Web.Endpoint.start_link()
    ExUnit.start(capture_log: true, exclude: without_cluster)

  {:error, reason} ->
    IO.puts(:stderr, """

    SKIPPED: no database for the plane (#{inspect(reason)}).
    Bring one up with `scripts/dev-up`, then `MIX_ENV=test mix ecto.migrate`.
    """)

    ExUnit.start(capture_log: true, exclude: [:test])
end
