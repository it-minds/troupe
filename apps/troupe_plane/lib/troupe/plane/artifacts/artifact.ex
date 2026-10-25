defmodule Troupe.Plane.Artifacts.Artifact do
  @moduledoc """
  One artifact (`Troupe.Plane.Artifacts`): whose it is, who may see it, where it came from,
  and the version its address serves. Its versions are `Troupe.Plane.Artifacts.Version`s.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "artifacts" do
    belongs_to(:owner, Troupe.Plane.Identity.User)
    belongs_to(:team, Troupe.Plane.Identity.Team)
    field(:title, :string)
    field(:kind, :string)
    # `organisation`, or `profile:<name>` for the people a profile's grants cover.
    field(:visibility, :string)
    # The profile of the session it came from, where that was a pod's.
    field(:profile, :string)
    # `session_id`, `agent` and `where` (`pod`, `laptop` or `person`).
    field(:origin, :map, default: %{})
    field(:version, :integer)
    # The version in force, and every version, which is what counts against the quota.
    field(:bytes, :integer, default: 0)
    field(:total_bytes, :integer, default: 0)

    has_many(:versions, Troupe.Plane.Artifacts.Version,
      references: :id,
      foreign_key: :artifact_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
