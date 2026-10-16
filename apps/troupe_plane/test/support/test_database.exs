defmodule Troupe.Plane.TestDatabase do
  @moduledoc """
  The plane's test database, made ready before a suite starts its repo.

  Every checkout has a database of its own (`config/config.exs` names it from the
  checkout's path): two checkouts' suites on one database lock the same rows from two
  sandboxes and deadlock. So the first run in a new checkout finds no database, and a
  branch with a new migration finds it unmigrated. This creates it where it is missing
  and runs whatever migration it lacks, then lets the repo go, so the suite starts it
  under its sandbox as before. A database that cannot be reached is left to the suite's
  own start, which skips loudly.

  A script, not a module of the build, so the worker's suite can load it as the plane's
  does: the worker's control-channel tests run against a real plane too.
  """

  alias Troupe.Plane.Repo

  @spec ensure() :: :ok | {:error, term()}
  def ensure do
    config = Repo.config()

    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok -> migrate()
      {:error, :already_up} -> migrate()
      # Two suites of one checkout starting together: the other one made it.
      {:error, message} when is_binary(message) -> if message =~ "already exists", do: migrate(), else: {:error, message}
      {:error, reason} -> {:error, reason}
    end
  end

  # On a plain pool of its own: the configured one is the suite's sandbox, which rolls
  # back whatever is written through it.
  defp migrate do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, pid} = Repo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2)

    try do
      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      :ok
    after
      Supervisor.stop(pid)
    end
  rescue
    error -> {:error, error}
  end
end
