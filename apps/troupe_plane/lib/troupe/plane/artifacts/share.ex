defmodule Troupe.Plane.Artifacts.Share do
  @moduledoc """
  One link to one artifact (`Troupe.Plane.Artifacts.Shares`): its role (`view` or `edit`),
  whether it is public, when it expires and when it was revoked, and who made it. The token
  in the link is never kept, only its SHA-256, so the table opens nothing to whoever reads
  it. The people the plane signed in through it are its `uses`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifact_shares" do
    field(:artifact_id, :string)
    field(:token_hash, :string)
    field(:role, :string)
    field(:public, :boolean, default: false)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:created_by, :string)

    has_many(:uses, Troupe.Plane.Artifacts.ShareUse, foreign_key: :share_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
