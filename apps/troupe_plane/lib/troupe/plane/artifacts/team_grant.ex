defmodule Troupe.Plane.Artifacts.TeamGrant do
  @moduledoc """
  A team that reads one artifact (`Troupe.Plane.Artifacts.Teams`): its members open it at
  `view`, who added the team and when. Gone with the team or the artifact.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "artifact_teams" do
    field(:artifact_id, :string, primary_key: true)
    belongs_to(:team, Troupe.Plane.Identity.Team, primary_key: true)
    field(:granted_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
