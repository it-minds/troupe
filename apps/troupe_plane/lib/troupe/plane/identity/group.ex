defmodule Troupe.Plane.Identity.Group do
  @moduledoc """
  A group in the identity provider.

  Groups are mirrored, never authored. A team is a group somebody enabled, and even
  then its membership still comes from the IdP — there is no "add a member" anywhere in
  Troupe, on purpose: two places to grant access is one place too many to revoke it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :external_id, :string
    field :display_name, :string

    has_one :team, Troupe.Plane.Identity.Team

    many_to_many :users, Troupe.Plane.Identity.User,
      join_through: Troupe.Plane.Identity.Membership,
      on_replace: :delete

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:external_id, :display_name])
    |> validate_required([:external_id, :display_name])
    |> unique_constraint(:external_id)
  end
end
