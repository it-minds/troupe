defmodule Troupe.Plane.Memory.Read do
  @moduledoc """
  What one running session read at its last turn (`Troupe.Plane.Memory`): each memory
  document's scope, name, version and hash, never its text, when the turn began, and where
  the session runs. A pod's session says so as its turn begins; a person's machine says it of
  its sessions with its poll of `me.memory`. One row per session, moved on by its next turn.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  @wheres ~w(pod machine)

  schema "memory_reads" do
    belongs_to(:owner, Troupe.Plane.Identity.User)
    field(:owner_subject, :string)
    field(:where, :string)
    field(:documents, {:array, :map}, default: [])
    field(:turn_at, :utc_datetime_usec)
    field(:seen_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(read, attrs) do
    read
    |> cast(attrs, [:session_id, :owner_id, :owner_subject, :where, :documents, :turn_at, :seen_at])
    |> validate_required([:session_id, :where, :seen_at])
    |> validate_inclusion(:where, @wheres)
  end
end
