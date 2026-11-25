defmodule Troupe.Plane.Proposals.Decline do
  @moduledoc """
  A person's "never for this" to a kind of proposal and its key (`artifact:<id>` for a
  trigger that reruns one), said in the session `session_id`: read before the next proposal
  of theirs is made, in any session.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "proposal_declines" do
    belongs_to(:user, Troupe.Plane.Identity.User)
    field(:kind, :string)
    field(:key, :string)
    field(:session_id, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
