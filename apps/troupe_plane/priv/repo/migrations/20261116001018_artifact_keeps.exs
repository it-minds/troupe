defmodule Troupe.Plane.Repo.Migrations.ArtifactKeeps do
  @moduledoc """
  Artifacts (#978): a person keeps an artifact at the top of their own gallery.

  `artifact_keeps` is one row per person and artifact they keep at the top, and when they
  did. It is the person's own view state, not the artifact's: nobody else reads it, and the
  artifact's owner is not told. Removing the person or the artifact removes the row; a row
  for an artifact the person may no longer open stays, unread, since the list only answers
  what they may open.
  """

  use Ecto.Migration

  def change do
    create table(:artifact_keeps, primary_key: false) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:artifact_keeps, [:artifact_id]))
  end
end
