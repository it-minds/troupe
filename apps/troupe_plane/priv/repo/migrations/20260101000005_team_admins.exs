defmodule Troupe.Plane.Repo.Migrations.TeamAdmins do
  @moduledoc """
  Who administers a team.

  A row rather than a column on `teams`, because a team can have several administrators
  and because a platform admin giving somebody the role is an event worth having a date
  on. Membership stays in the identity provider — this is a *role* within Troupe, granted
  by a platform admin, and it is the only such role Troupe assigns.
  """

  use Ecto.Migration

  def change do
    create table(:team_admins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      # The subject rather than a user id: a platform admin can name somebody who has not
      # logged in yet, and the role should be waiting when they do.
      add :subject, :string, null: false
      add :granted_by, :string, null: false
      add :granted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:team_admins, [:team_id, :subject])
    create index(:team_admins, [:subject])
  end
end
