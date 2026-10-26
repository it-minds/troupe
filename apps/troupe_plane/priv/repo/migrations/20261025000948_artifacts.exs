defmodule Troupe.Plane.Repo.Migrations.Artifacts do
  @moduledoc """
  Artifacts (#62): a page, a document or a file an agent or a person published, kept as
  versions at one address, its bytes in the object store under `artifacts/<id>/<n>/`.

  `artifacts` is one row per artifact: whose it is (by id, so a re-key keeps it; nulled
  when the person is removed, so an organisation's report outlives its author's account),
  the team its bytes count against, who may see it (`organisation` or `profile:<name>`),
  where it came from and the version in force. `artifact_versions` is one row per version,
  never updated: its files with their hashes and types, and who published it when.

  `artifact_tickets` holds the one-time tickets the artifacts host has redeemed, so a
  ticket copied out of a browser's history opens nothing a second time.

  And each team's quota for what its artifacts hold, every version counted.
  """

  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:owner_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:team_id, references(:teams, type: :binary_id, on_delete: :nilify_all))
      add(:title, :string, null: false)
      add(:kind, :string, null: false)
      add(:visibility, :string, null: false)
      add(:profile, :string)
      add(:origin, :map, null: false, default: %{})
      add(:version, :integer, null: false)
      add(:bytes, :bigint, null: false, default: 0)
      add(:total_bytes, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:artifacts, [:owner_id]))
    create(index(:artifacts, [:team_id]))
    create(index(:artifacts, [:visibility]))

    create table(:artifact_versions, primary_key: false) do
      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:n, :integer, primary_key: true)
      add(:hash, :string, null: false)
      add(:bytes, :bigint, null: false)
      add(:files, {:array, :map}, null: false, default: [])
      add(:published_by, :string, null: false)
      add(:published_at, :utc_datetime_usec, null: false)
    end

    create table(:artifact_tickets, primary_key: false) do
      add(:nonce, :string, primary_key: true)
      add(:used_at, :utc_datetime_usec, null: false)
    end

    create(index(:artifact_tickets, [:used_at]))

    alter table(:teams) do
      add(:artifact_quota_bytes, :bigint, null: false, default: 1_073_741_824)
    end
  end
end
