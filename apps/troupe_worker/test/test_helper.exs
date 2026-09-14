Logger.configure(level: :warning)

# One test in this app — the end-to-end control channel — needs a real plane on the
# other end of the socket, and a plane needs a database. Started here rather than in a
# case template because nothing else here wants one, and absent quietly because the rest
# of the suite does not depend on it.
case Troupe.Plane.Repo.start_link(pool: Ecto.Adapters.SQL.Sandbox) do
  {:ok, _pid} -> Ecto.Adapters.SQL.Sandbox.mode(Troupe.Plane.Repo, :manual)
  {:error, _reason} -> :ok
end

# Taking a real plane down, for the handful of tests that bring one up. A script, so
# it stays out of this app's beams and out of the boundary check; see its moduledoc.
Code.require_file("support/plane_helper.exs", __DIR__)

ExUnit.start(capture_log: true)
