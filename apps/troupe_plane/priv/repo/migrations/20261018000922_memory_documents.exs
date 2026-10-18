defmodule Troupe.Plane.Repo.Migrations.MemoryDocuments do
  @moduledoc """
  The organisation's memory documents (#55): the organisation's, each team's and each
  worker profile's, every version kept.

  A save is a new row, never an update, so "what did the design team's memory say last
  Tuesday, and who changed it" is a read. `owner` is empty for the organisation's, the
  team's id for a team's (a team's name may change and its memory stays its own), and the
  profile's name for a profile's, as a profile is keyed.
  """

  use Ecto.Migration

  def change do
    create table(:memory_documents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:scope, :string, null: false)
      add(:owner, :string, null: false, default: "")
      # Monotonic per document, so a person can say "version 3" out loud.
      add(:version, :integer, null: false)
      add(:text, :text, null: false, default: "")
      add(:hash, :string, null: false)
      add(:changed_by, :string, null: false)

      # No `updated_at`: a version is immutable.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:memory_documents, [:scope, :owner, :version]))
  end
end
