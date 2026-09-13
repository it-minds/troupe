defmodule Troupe.Plane.Repo.Migrations.PlatformSettings do
  @moduledoc """
  The settings a platform admin may change without a deploy.

  Everything here already had a value: it came from an environment variable, which is the
  right home for what a deployment decides and the wrong one for what an operator does. A
  plane whose administrators are the wrong group cannot be fixed from the console that the
  wrong group locked them out of, and "edit the Helm values, roll the deployment" is not a
  repair, it is an outage with a change request in front of it.

  So this table is an *override*, never the source: a key with no row here reads whatever
  the plane was deployed with, and deleting a row puts it back. That ordering is what
  makes the feature safe to have — the deployment remains the floor, and the worst a bad
  setting can do is be reset.

  Values are stored as text and parsed against the setting's declared type on the way out.
  A column per type would be five columns and a case; text and a parser is one column and
  the same case, and the parse is where a value is refused rather than at read time.
  """

  use Ecto.Migration

  def change do
    create table(:platform_settings, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :text, null: false)
      add(:updated_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
