defmodule Troupe.Plane.Repo.Migrations.GithubSweepAndGitops do
  @moduledoc """
  Issue #147's rest and #653's GitOps half.

  - `trigger_runs.reason`: why a firing started no session, for a run the plane skipped
    over a cap (its trigger's concurrency, its profile's or team's runs on a repository at
    once). Null for a run that started one.
  - `github_app.resource_generation`: in GitOps mode, the generation of the `GitHubApp`
    resource the App's settings were last read from; null for an App set through the admin
    API.
  """

  use Ecto.Migration

  def change do
    alter table(:trigger_runs) do
      add(:reason, :text)
    end

    alter table(:github_app) do
      add(:resource_generation, :bigint)
    end
  end
end
