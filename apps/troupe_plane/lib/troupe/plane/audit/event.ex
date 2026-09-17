defmodule Troupe.Plane.Audit.Event do
  @moduledoc """
  One recorded administrative change.

  `actor` is what made it. `on_behalf_of` is whose authority it was made under, and both
  are written even when they are the same — a field that is null when they match is one a
  reader a year later cannot interpret.

  ## The chain

  `hash` is this row's digest over its own content; `prev_hash` is the digest of the row
  before it. Excluding `prev_hash` from what is hashed is what lets a verifier recompute
  the chain from stored data alone — the same rule, and the same `Canonical.hash/1`, as the
  session log has used since W1.

  Both are nullable because a deployment upgrading into the chain has rows from before it.
  Those are reported as unchained rather than being rewritten with hashes computed now,
  which would be a trail claiming to be verified back to a row nothing verified.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_events" do
    field(:actor, :string)
    field(:on_behalf_of, :string)
    field(:action, :string)
    field(:subject_kind, :string)
    field(:subject_id, :string)
    field(:detail, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    field(:hash, :string)
    field(:prev_hash, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor,
      :on_behalf_of,
      :action,
      :subject_kind,
      :subject_id,
      :detail,
      :occurred_at,
      :hash,
      :prev_hash
    ])
    |> validate_required([:actor, :on_behalf_of, :action, :subject_kind, :occurred_at])
  end
end
