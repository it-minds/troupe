defmodule Troupe.Plane.Proposals.Made do
  @moduledoc """
  A trigger a person's yes to a proposal made: the team's trigger, the person, the session
  and the proposal it came from, and the artifact it reruns. Gone with the trigger, so a
  trigger deleted no longer counts against the person and no longer reruns the artifact.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "trigger_proposals" do
    belongs_to(:trigger, Troupe.Plane.Triggers.Trigger)
    belongs_to(:team, Troupe.Plane.Identity.Team)
    belongs_to(:user, Troupe.Plane.Identity.User)
    field(:session_id, :string)
    field(:proposal, :string)
    field(:artifact_id, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
