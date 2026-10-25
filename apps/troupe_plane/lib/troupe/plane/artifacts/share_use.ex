defmodule Troupe.Plane.Artifacts.ShareUse do
  @moduledoc """
  A person the plane signed in through a link (`Troupe.Plane.Artifacts.Share`): when first
  and last, and whether the owner revoked them, which leaves the link working for everybody
  else who holds it.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "artifact_share_uses" do
    belongs_to(:share, Troupe.Plane.Artifacts.Share, primary_key: true)
    belongs_to(:user, Troupe.Plane.Identity.User, primary_key: true)
    field(:first_used_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
