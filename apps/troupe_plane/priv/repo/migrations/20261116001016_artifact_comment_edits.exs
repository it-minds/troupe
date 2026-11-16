defmodule Troupe.Plane.Repo.Migrations.ArtifactCommentEdits do
  @moduledoc """
  A comment in an artifact's thread can be edited by its author (#979): `edited_at` says
  when it last was, `nil` for one never edited, so a thread marks it as edited. A deleted
  comment is its row removed, which needs nothing new. Additive only.
  """

  use Ecto.Migration

  def change do
    alter table(:artifact_comments) do
      add(:edited_at, :utc_datetime_usec)
    end
  end
end
