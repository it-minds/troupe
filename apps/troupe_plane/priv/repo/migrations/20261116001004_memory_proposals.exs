defmodule Troupe.Plane.Repo.Migrations.MemoryProposals do
  @moduledoc """
  What an agent proposes for a team's or the organisation's memory (#55): one entry under a
  topic, with the session, the agent and the person it came from, waiting for an
  administrator who may change that level to accept or decline it. Accepted, it is written
  into the document as an entry, and the row keeps the version it came in; declined, the
  row keeps the sentence the session was told. Never the document: a pending proposal is
  read by no session.

  A team's proposals go with the team, a person's with the person.
  """

  use Ecto.Migration

  def change do
    create table(:memory_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # `team` or `organisation`: the level proposed for.
      add :scope, :string, null: false
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all)
      add :topic, :string, null: false
      add :entry, :text, null: false
      add :session_id, :string
      add :agent, :string
      # `pod` or `machine`: where the session ran, which is how its decision reaches it.
      add :where, :string, null: false
      add :proposer_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :proposer_subject, :string, null: false
      # `pending`, `accepted` or `declined`.
      add :state, :string, null: false, default: "pending"
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      add :reason, :text
      add :version, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_proposals, [:state, :scope])
    create index(:memory_proposals, [:proposer_id])
    create index(:memory_proposals, [:team_id])
  end
end
