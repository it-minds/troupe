defmodule Troupe.Plane.Repo.Migrations.ArtifactThumbnails do
  @moduledoc """
  Artifacts (#62, #977): a picture of the page on its gallery card, which the publisher sends
  with the version.

  `artifact_versions.thumbnail` is that version's picture, or null for none: its content
  type, size and SHA-256, and the version whose object it is where a later version carried it
  unchanged (`stored_in`). The bytes are in the object store under
  `artifacts/<id>/thumbnails/<n>`. `artifacts.thumbnail` is the same for the version the
  artifact's address serves, kept beside `bytes` so a list reads no version to draw a card.
  Both additive and null by default: every artifact there is keeps its card as it was.
  """

  use Ecto.Migration

  def change do
    alter table(:artifact_versions) do
      add(:thumbnail, :map)
    end

    alter table(:artifacts) do
      add(:thumbnail, :map)
    end
  end
end
