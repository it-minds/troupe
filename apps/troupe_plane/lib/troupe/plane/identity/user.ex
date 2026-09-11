defmodule Troupe.Plane.Identity.User do
  @moduledoc """
  A person, as the identity provider describes them.

  `subject` — the IdP's `sub` — is the identity. Email and display name are labels that
  change when people marry, move team, or correct a typo, and a system that keyed on
  either would lose track of them when they did.

  Nothing here is editable in Troupe. Users arrive by SCIM push or are created just in
  time at login, and both paths write the same row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :subject, :string
    field :external_id, :string
    field :email, :string
    field :display_name, :string
    field :active, :boolean, default: true

    many_to_many :groups, Troupe.Plane.Identity.Group,
      join_through: Troupe.Plane.Identity.Membership,
      on_replace: :delete

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:subject, :external_id, :email, :display_name, :active])
    |> validate_required([:subject])
    |> unique_constraint(:subject)
  end
end
