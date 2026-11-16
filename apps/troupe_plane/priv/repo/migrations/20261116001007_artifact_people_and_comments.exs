defmodule Troupe.Plane.Repo.Migrations.ArtifactPeopleAndComments do
  @moduledoc """
  Artifacts (#62), the last slice: an artifact shared with picked people, each at a role,
  and one thread of comments per artifact.

  `artifact_people` is one row per person an owner shared an artifact with by name: the
  role it gives them (`view`, `comment` or `edit`), who gave it and when. Removing the
  person or the artifact removes the row; there is nothing to keep of a grant whose person
  or artifact is gone.

  `artifact_comments` is one row per comment: its author (the person, nulled if they are
  removed, with the subject kept so the thread still says who wrote it), the text, and
  when. The artifact's deletion takes its thread with it, as it takes its versions.
  """

  use Ecto.Migration

  def change do
    create table(:artifact_people, primary_key: false) do
      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:role, :string, null: false)
      add(:granted_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:artifact_people, [:user_id]))

    create table(:artifact_comments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:author_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:author_subject, :string, null: false)
      add(:body, :text, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:artifact_comments, [:artifact_id, :inserted_at]))
  end
end
