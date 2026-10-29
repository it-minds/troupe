defmodule Troupe.Plane.Repo.Migrations.ArtifactOwnerTeam do
  @moduledoc """
  An artifact may be a team's, whose members own it (#62).

  `artifacts.owner_team_id` names the team that owns it; null, it is `owner_id`'s person's
  alone, as every artifact was. The person who published it stays in `owner_id` whatever
  the team, so a team that is deleted hands the artifact back to them (the key is nulled,
  not the row) and each version still says who published it.
  """

  use Ecto.Migration

  def change do
    alter table(:artifacts) do
      add(:owner_team_id, references(:teams, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:artifacts, [:owner_team_id]))
  end
end
