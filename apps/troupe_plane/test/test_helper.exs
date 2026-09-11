alias Ecto.Adapters.SQL.Sandbox
alias Troupe.Plane.Repo

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

# The plane is the one app in the umbrella that needs a database. Without one its tests
# are skipped — loudly, with the command that brings it up — rather than failing in a way
# that looks like a bug in the code.
case Repo.start_link(pool: Sandbox) do
  {:ok, _pid} ->
    Sandbox.mode(Repo, :manual)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Troupe.Plane.PubSub)
    {:ok, _} = Troupe.Plane.Web.Endpoint.start_link()
    ExUnit.start(capture_log: true)

  {:error, reason} ->
    IO.puts(:stderr, """

    SKIPPED: no database for the plane (#{inspect(reason)}).
    Bring one up with `scripts/dev-up`, then `MIX_ENV=test mix ecto.migrate`.
    """)

    ExUnit.start(capture_log: true, exclude: [:test])
end
