defmodule Troupe.Plane.Repo.Migrations.ArtifactOpenedAt do
  @moduledoc """
  When an artifact was last opened (#981): set when somebody opens it through the plane
  (`artifact.open`), on the artifacts host's entry page, or through a public link, at most
  once an hour. What `artifacts_keep_unopened_days` counts from, with its last publish or
  change (`updated_at`), whichever is later; so a row from before this column, `null`, counts
  from its last publish, and nothing needs filling in.
  """

  use Ecto.Migration

  def change do
    alter table(:artifacts) do
      add :opened_at, :utc_datetime_usec
    end
  end
end
