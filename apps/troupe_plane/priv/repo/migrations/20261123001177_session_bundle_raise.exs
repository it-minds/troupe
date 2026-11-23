defmodule Troupe.Plane.Repo.Migrations.SessionBundleRaise do
  @moduledoc """
  A session's owner raises it to its channel's current bundle version (#1177).

  `bundle_channel` is the channel its `bundle_version` is a version of, so a pin names one
  document. A row pinned before the column takes its profile's channel, which is what every
  wake read the number against until now; a row whose profile is gone keeps none and reads
  as before. `bundle_raise_to` and `bundle_raise_by` are a raise asked for and not yet
  taken by a pod: the version, and who asked.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :bundle_channel, :string
      add :bundle_raise_to, :integer
      add :bundle_raise_by, :string
    end

    execute("""
    UPDATE sessions SET bundle_channel = profiles.config_bundle_channel
    FROM profiles
    WHERE profiles.name = sessions.profile AND sessions.bundle_version IS NOT NULL
    """)
  end

  def down do
    alter table(:sessions) do
      remove :bundle_channel
      remove :bundle_raise_to
      remove :bundle_raise_by
    end
  end
end
