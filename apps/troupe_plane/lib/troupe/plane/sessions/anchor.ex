defmodule Troupe.Plane.Sessions.Anchor do
  @moduledoc """
  A sealed segment head, which doubles as an audit anchor.

  The worker seals a segment, uploads it, and reports where it got to. The plane keeps
  the hash but not the contents, so tampering with a stored segment is detectable
  without the plane ever having been able to read it.

  The epoch in the key is the fence: an anchor from an epoch the session has moved past
  is refused, so a pod presumed lost cannot write history into a session that has been
  activated somewhere else.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "anchors" do
    field :session_id, :string
    field :epoch, :integer
    field :first_seq, :integer
    field :last_seq, :integer
    field :head_hash, :string
    field :object_key, :string
    field :bytes, :integer, default: 0
    field :sealed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(anchor, attrs) do
    anchor
    |> cast(attrs, [
      :session_id,
      :epoch,
      :first_seq,
      :last_seq,
      :head_hash,
      :object_key,
      :bytes,
      :sealed_at
    ])
    |> validate_required([:session_id, :epoch, :first_seq, :last_seq, :head_hash, :object_key, :sealed_at])
    |> unique_constraint([:session_id, :epoch, :last_seq])
  end
end
