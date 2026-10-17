defmodule Troupe.Plane.Repo.Migrations.TeamGithub do
  @moduledoc """
  What a team's sessions may do on GitHub (#147 slice 4, #653): `teams.github`.

  The repositories the team's sessions and triggers may name (`owner/name`, or `owner/*`),
  and its caps on pushes per run and runs on a repository at once. Set by the team's own
  administrators. Null for a team that has listed nothing, which names no repository.
  """

  use Ecto.Migration

  def change do
    alter table(:teams) do
      add(:github, :map)
    end
  end
end
