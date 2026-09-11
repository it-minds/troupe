defmodule Troupe.Plane.Release do
  @moduledoc """
  What a release can be told to do before it starts serving.

  A release has no Mix, so `mix ecto.migrate` is not available in a container. This is
  the same work reached the way a release reaches anything: `bin/troupe_plane eval
  'Troupe.Plane.Release.migrate()'`, which is what the deployment runs before the plane
  comes up.

  Deliberately not run from the application's `start/2`. Two replicas starting at once
  would both migrate, and a migration that failed would look like a plane that would not
  boot rather than like a migration that failed.
  """

  @app :troupe_plane

  @doc "Bring the database up to date."
  @spec migrate() :: :ok
  def migrate do
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Roll one repo back to a version. For an operator with a problem, not for a deploy."
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos do
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
