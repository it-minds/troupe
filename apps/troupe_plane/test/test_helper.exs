alias Ecto.Adapters.SQL.Sandbox
alias Troupe.Plane.Repo

# The plane is the one app in the umbrella that needs a database. Without one its
# tests are skipped — loudly, with the command that brings it up — rather than failing
# in a way that looks like a bug in the code.
case Repo.start_link(pool: Sandbox) do
  {:ok, _pid} ->
    Sandbox.mode(Repo, :manual)
    ExUnit.start(capture_log: true)

  {:error, reason} ->
    IO.puts(:stderr, """

    SKIPPED: no database for the plane (#{inspect(reason)}).
    Bring one up with `scripts/dev-up`, then `MIX_ENV=test mix ecto.migrate`.
    """)

    ExUnit.start(capture_log: true, exclude: [:test])
end
