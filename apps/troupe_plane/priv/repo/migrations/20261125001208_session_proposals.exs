defmodule Troupe.Plane.Repo.Migrations.SessionProposals do
  @moduledoc """
  What the harness proposes in a pod session's chat (#1208), and what became of it.

  `proposal_declines` keeps a person's "never for this": the kind of proposal and its key
  (`artifact:<id>` for a trigger that reruns one), read before the next proposal is made
  in any session of theirs. `trigger_proposals` keeps each trigger a yes made: the team's
  trigger, the person who said yes, the session and the artifact it reruns, so the plane
  can say a trigger already reruns an artifact and count a person's in a team. A trigger
  deleted takes its row with it; a person removed takes theirs.

  `teams.members_may_schedule`: whether a member may turn one on in that team, on unless
  a team administrator turns it off, under the platform setting of the same name.
  """

  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :members_may_schedule, :boolean, null: false, default: true
    end

    create table(:proposal_declines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :key, :string, null: false
      add :session_id, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:proposal_declines, [:user_id, :kind, :key])

    create table(:trigger_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :trigger_id, references(:triggers, type: :binary_id, on_delete: :delete_all), null: false
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :session_id, :string, null: false
      add :proposal, :string, null: false
      add :artifact_id, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # A team's principal an owner shared one artifact with by name, as a person is: what
    # lets a trigger's runs publish the next version of an artifact its sponsor owns alone.
    create table(:artifact_principals, primary_key: false) do
      add :artifact_id, references(:artifacts, type: :string, on_delete: :delete_all), primary_key: true
      add :principal_id, references(:service_principals, type: :binary_id, on_delete: :delete_all), primary_key: true
      add :role, :string, null: false
      add :granted_by, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifact_principals, [:principal_id])

    create unique_index(:trigger_proposals, [:trigger_id])
    create unique_index(:trigger_proposals, [:session_id, :proposal])
    create index(:trigger_proposals, [:team_id, :user_id])
    create index(:trigger_proposals, [:artifact_id])
  end
end
