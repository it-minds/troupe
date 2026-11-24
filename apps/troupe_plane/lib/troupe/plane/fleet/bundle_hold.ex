defmodule Troupe.Plane.Fleet.BundleHold do
  @moduledoc """
  A channel a repository holds: a `ConfigBundle` resource names it, and the plane's GitOps
  pass publishes what the resource says as the channel's versions.

  `hash` and `version` are what the resource last published, or the version it found
  already current and adopted. The pass compares a resource's content with this hash and
  never with the channel's current version, so a version an administrator retires stays
  retired rather than being published again a pass later. `resource_generation` is the
  resource's `metadata.generation` at that read, and `source_revision` the revision its
  `troupe.dev/revision` annotation named, shown and never trusted.

  While the row exists, `admin.bundle.publish` on the channel is refused; it goes when the
  resource does, and the channel is published by hand again with its versions kept.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:channel, :string, autogenerate: false}

  schema "config_bundle_holds" do
    field(:hash, :string)
    field(:version, :integer)
    field(:resource_generation, :integer)
    field(:source_revision, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(hold, attrs) do
    hold
    |> cast(attrs, [:channel, :hash, :version, :resource_generation, :source_revision])
    |> validate_required([:channel, :hash, :version])
  end
end
