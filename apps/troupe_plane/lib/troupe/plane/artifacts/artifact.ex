defmodule Troupe.Plane.Artifacts.Artifact do
  @moduledoc """
  One artifact (`Troupe.Plane.Artifacts`): whose it is, who may see it, where it came from,
  and the version its address serves. Its versions are `Troupe.Plane.Artifacts.Version`s.

  Whose it is is `owner`, the person who published it first, unless `owner_team` names a
  team: then every member and administrator of that team owns it, and the person is kept
  only as who to hand it back to when the team is deleted (the key is nulled, not the row).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "artifacts" do
    belongs_to(:owner, Troupe.Plane.Identity.User)
    # The team that owns it, or nil for the person's alone.
    belongs_to(:owner_team, Troupe.Plane.Identity.Team)
    # The team its bytes count against.
    belongs_to(:team, Troupe.Plane.Identity.Team)
    field(:title, :string)
    field(:kind, :string)
    # `organisation`, or `profile:<name>` for the people a profile's grants cover.
    field(:visibility, :string)
    # The profile of the session it came from, where that was a pod's.
    field(:profile, :string)
    # `session_id`, `agent` and `where` (`pod`, `laptop` or `person`).
    field(:origin, :map, default: %{})
    # The newest version.
    field(:version, :integer)
    # The version the owner pinned as the one its address serves, or nil for the newest.
    field(:pinned, :integer)
    # The owner's switch for this artifact's public links, under the administrator's.
    field(:public_links, :boolean, default: true)
    # The version in force, and every version, which is what counts against the quota.
    field(:bytes, :integer, default: 0)
    field(:total_bytes, :integer, default: 0)

    has_many(:versions, Troupe.Plane.Artifacts.Version,
      references: :id,
      foreign_key: :artifact_id
    )

    has_many(:shares, Troupe.Plane.Artifacts.Share, references: :id, foreign_key: :artifact_id)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
