defmodule Troupe.Plane.Identity.Tombstone do
  @moduledoc """
  What is kept of a person the identity provider removed.

  A SCIM `DELETE` takes their row: a lookup by the id the provider holds answers `404`,
  and nobody signs in as them. What has to outlive them is here and on the rows that name
  them. Their sessions are owned by this tombstone's marker (`marker/1`) rather than by
  their subject, so somebody who later arrives under the same subject is a new person and
  does not inherit them; the audit trail and every `*_by` keep the name they were written
  with. `kms_name` is where what they stored at the key manager still is, which an erasure
  of their sessions needs, and which nobody new is given.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  # What a removed person's sessions name as their owner. No identity provider's subject
  # starts with it, and a principal's starts with `svc:`.
  @prefix "removed:"

  schema "person_tombstones" do
    field(:former_id, :binary_id)
    field(:subject, :string)
    field(:external_id, :string)
    field(:user_name, :string)
    field(:display_name, :string)
    field(:kms_name, :string)
    field(:removed_by, :string)
    field(:removed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [
      :id,
      :former_id,
      :subject,
      :external_id,
      :user_name,
      :display_name,
      :kms_name,
      :removed_by,
      :removed_at
    ])
    |> validate_required([:former_id, :subject, :kms_name, :removed_by, :removed_at])
    |> unique_constraint(:kms_name)
  end

  @doc "The owner a removed person's sessions carry: the \"removed person\" marker."
  @spec marker(t()) :: String.t()
  def marker(%__MODULE__{id: id}), do: @prefix <> id

  @doc "The tombstone id a marker names, or `:error` for an ordinary subject."
  @spec parse_marker(String.t() | nil) :: {:ok, Ecto.UUID.t()} | :error
  def parse_marker(@prefix <> id), do: Ecto.UUID.cast(id)
  def parse_marker(_subject), do: :error
end
