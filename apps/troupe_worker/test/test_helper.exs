Logger.configure(level: :warning)

# One test in this app — the end-to-end control channel — needs a real plane on the
# other end of the socket, and a plane needs a database. Started here rather than in a
# case template because nothing else here wants one, and absent quietly because the rest
# of the suite does not depend on it.
case Troupe.Plane.Repo.start_link(pool: Ecto.Adapters.SQL.Sandbox) do
  {:ok, _pid} -> Ecto.Adapters.SQL.Sandbox.mode(Troupe.Plane.Repo, :manual)
  {:error, _reason} -> :ok
end

ExUnit.start(capture_log: true)
