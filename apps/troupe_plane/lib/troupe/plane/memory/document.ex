defmodule Troupe.Plane.Memory.Document do
  @moduledoc """
  One version of one memory document: the organisation's, a team's, a worker profile's or a
  person's own (`Troupe.Plane.Memory`). Never updated; a save is the next version.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Protocol.Memory, as: Shape

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memory_documents" do
    field(:scope, :string)
    # Empty for the organisation's, the team's id, the profile's name, or the person's id.
    field(:owner, :string, default: "")
    field(:version, :integer)
    field(:text, :string, default: "")
    field(:hash, :string)
    field(:changed_by, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    # An empty owner is the organisation's, and an empty text a document cleared: both kept
    # as they are rather than cast to nil.
    |> cast(attrs, [:scope, :owner, :version, :text, :hash, :changed_by], empty_values: [])
    |> validate_required([:scope, :version, :hash, :changed_by])
    |> validate_inclusion(:scope, Shape.scopes())
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:scope, :owner, :version],
      name: :memory_documents_scope_owner_version_index
    )
  end
end
