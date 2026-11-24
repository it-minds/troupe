defmodule Troupe.Plane.Repo.Migrations.ConfigBundleResources do
  @moduledoc """
  In GitOps mode a repository may hold a channel's bundle as a `ConfigBundle` resource
  (#1198), which the plane publishes as the channel's next version when its content changes.

  `config_bundle_holds` is one row per channel a resource holds: the hash and version the
  resource last published or adopted, the resource's generation and the revision its
  `troupe.dev/revision` annotation named, if any. A channel with no row is published by
  hand, as every channel was. `config_bundles.resource_generation` and `source_revision` are
  the same two values on a version the pass published, and `NULL` on one a person did.

  Additive only, so a plane from before it ignores both and a rollback keeps working.
  """

  use Ecto.Migration

  def change do
    create table(:config_bundle_holds, primary_key: false) do
      add(:channel, :string, primary_key: true)
      add(:hash, :string, null: false)
      add(:version, :integer, null: false)
      add(:resource_generation, :bigint)
      add(:source_revision, :string)

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:config_bundles) do
      add(:resource_generation, :bigint)
      add(:source_revision, :string)
    end
  end
end
