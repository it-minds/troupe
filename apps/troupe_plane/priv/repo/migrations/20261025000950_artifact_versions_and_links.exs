defmodule Troupe.Plane.Repo.Migrations.ArtifactVersionsAndLinks do
  @moduledoc """
  Artifacts (#62), second slice: versions with a note, a rollback and a pin; links that
  honour the plane's sign-in; public links behind an administrator's switch; an edit's
  preview; and an upload handle for a version too large for one call.

  `artifact_versions.note` is what its publisher said of it ("rolled back to v3" for a
  rollback). `artifacts.pinned` is the version the owner pinned as the current one, null
  for the newest; `artifacts.public_links` is the owner's switch for this artifact's public
  links, which the administrator's `artifacts_public_links` stands above.

  `artifact_shares` is one row per link: the SHA-256 of its token (the token itself is
  never kept), its role, whether it is public, when it expires and when it was revoked.
  `artifact_share_uses` is one row per person the plane signed in through a link, so a
  link's holders are listed and revoked one by one.

  `artifact_previews` holds an edit's text while its person looks at it on the artifacts
  host, for an hour at most. `artifact_uploads` holds what an upload handle announced,
  while its files go straight into the object store under `artifact-uploads/<handle>/`.
  """

  use Ecto.Migration

  def change do
    alter table(:artifact_versions) do
      add(:note, :string, size: 500)
      add(:rolled_back_to, :integer)
    end

    alter table(:artifacts) do
      add(:pinned, :integer)
      add(:public_links, :boolean, null: false, default: true)
    end

    create table(:artifact_shares, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:token_hash, :string, null: false)
      add(:role, :string, null: false)
      add(:public, :boolean, null: false, default: false)
      add(:expires_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:created_by, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:artifact_shares, [:token_hash]))
    create(index(:artifact_shares, [:artifact_id]))

    create table(:artifact_share_uses, primary_key: false) do
      add(:share_id, references(:artifact_shares, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:first_used_at, :utc_datetime_usec, null: false)
      add(:last_used_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
    end

    create(index(:artifact_share_uses, [:user_id]))

    create table(:artifact_previews, primary_key: false) do
      add(:nonce, :string, primary_key: true)

      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:subject, :string, null: false)
      add(:base, :integer, null: false)
      add(:path, :string, null: false)
      add(:content_type, :string, null: false)
      add(:body, :binary, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:artifact_previews, [:inserted_at]))

    create table(:artifact_uploads, primary_key: false) do
      add(:handle, :string, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:files, {:array, :map}, null: false, default: [])
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:artifact_uploads, [:expires_at]))
  end
end
