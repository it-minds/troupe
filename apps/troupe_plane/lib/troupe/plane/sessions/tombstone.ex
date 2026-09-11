defmodule Troupe.Plane.Sessions.Tombstone do
  @moduledoc """
  What is left of an erased session.

  The final head hash, why it was erased, and who asked — and nothing else, because
  everything else is the thing that was erased. The hash is kept deliberately: it is the
  last link of the audit chain, and an erasure that also erased the proof that the
  session ever existed would be indistinguishable from a session that was tampered out
  of the index.

  `applied_by` is the list of pods that have carried the erasure out on their own disk.
  A pod that was offline when it ran applies it on enrol, before serving anything, and
  this is how it learns what to apply.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "tombstones" do
    field :session_id, :string
    field :head_hash, :string
    field :reason, :string
    field :actor, :string
    field :erased_at, :utc_datetime_usec
    field :applied_by, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [:session_id, :head_hash, :reason, :actor, :erased_at, :applied_by]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, @fields)
    |> validate_required([:session_id, :reason, :actor, :erased_at])
    |> unique_constraint(:session_id)
  end
end
