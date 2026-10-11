defmodule Troupe.Plane.Repo.Migrations.ClientVersions do
  @moduledoc """
  The plane's version policy for its clients (#66, Decision 868): per component — the
  terminal, the daemon, the desktop app — the version clients are nudged to, the oldest one
  this plane serves, and the versions it serves to nobody.

  One row per component, keyed by its name, written only when an administrator first sets
  something: a plane with no row for a component holds no policy for it and refuses nobody,
  which is what every plane upgrading into this does until somebody decides otherwise.
  """

  use Ecto.Migration

  def change do
    create table(:client_versions, primary_key: false) do
      add(:component, :string, primary_key: true)
      add(:recommended, :string)
      add(:minimum, :string)
      add(:blocked, {:array, :string}, null: false, default: [])
      add(:updated_by, :string)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
