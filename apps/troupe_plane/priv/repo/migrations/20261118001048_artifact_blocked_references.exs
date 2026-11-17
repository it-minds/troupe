defmodule Troupe.Plane.Repo.Migrations.ArtifactBlockedReferences do
  @moduledoc """
  Artifacts (#1081): how many references the artifacts host blocks in the version an
  artifact's address serves, kept beside `bytes` and `thumbnail` so a list reads no version
  to say it. Each version's own list is on its files (`files[].blocked`), read at publish.
  Additive and zero by default: an artifact published before the check is not read again.
  """

  use Ecto.Migration

  def change do
    alter table(:artifacts) do
      add(:blocked, :integer, null: false, default: 0)
    end
  end
end
