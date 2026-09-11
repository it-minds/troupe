defmodule Troupe.Plane.Sessions.Session do
  @moduledoc """
  The plane's row for a session: metadata, never content.

  Everything here is something a listing or a placement decision needs. What was said,
  what was read, what was written — none of it crosses into this database, and a done
  item proves it by looking for a marker string in a dump.

  `epoch` is the one field with teeth. It is minted here and nowhere else, it appears in
  the object keys of every segment written under it, and a seal report from an older
  epoch is rejected. That is what stops a pod presumed lost from appending to a session
  that has moved on.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  @states ~w(active dormant read_only erased)
  @visibilities ~w(private team)

  schema "sessions" do
    belongs_to :owner, Troupe.Plane.Identity.User
    field :owner_subject, :string
    belongs_to :team, Troupe.Plane.Identity.Team
    field :profile, :string
    field :visibility, :string, default: "private"
    field :state, :string, default: "active"

    field :epoch, :integer, default: 1
    belongs_to :worker, Troupe.Plane.Fleet.Worker

    field :title, :string
    field :workspace_source, :map
    field :bundle_version, :integer
    field :retention_class, :string
    field :pinned, :boolean, default: false
    field :pinned_by, :string
    field :pinned_at, :utc_datetime_usec

    field :last_active_at, :utc_datetime_usec
    field :last_seq, :integer, default: 0
    field :head_hash, :string
    field :object_bytes, :integer, default: 0
    field :workspace_bytes, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The four states a session can be in."
  @spec states() :: [String.t()]
  def states, do: @states

  @fields [
    :id,
    :owner_id,
    :owner_subject,
    :team_id,
    :profile,
    :visibility,
    :state,
    :epoch,
    :worker_id,
    :title,
    :workspace_source,
    :bundle_version,
    :retention_class,
    :pinned,
    :pinned_by,
    :pinned_at,
    :last_active_at,
    :last_seq,
    :head_hash,
    :object_bytes,
    :workspace_bytes
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @fields)
    |> validate_required([:id, :owner_subject, :profile])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:visibility, @visibilities)
  end
end
