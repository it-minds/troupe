defmodule Troupe.Plane.Repo.Migrations.SessionArchived do
  @moduledoc """
  Whether a session is archived (#1005): taken out of the session list for everyone who
  sees it, by its owner, and kept whole. Who did it and when, as a pin records them. A row
  from before the column is not archived.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:archived, :boolean, null: false, default: false)
      add(:archived_by, :string)
      add(:archived_at, :utc_datetime_usec)
    end
  end
end
