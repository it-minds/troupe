defmodule Troupe.Plane.Identity.TeamGroupLink do
  @moduledoc """
  One identity-provider group a team draws its members from.

  A team used to *be* a group. It links to any number of them now, and its membership is
  the union — so a person in two linked groups is in the team once, and a team with no
  links has no members, which is a valid and useful state while somebody is setting one
  up rather than a broken one.

  **Nothing here is membership.** A link says *which groups count*; who is in them is the
  provider's answer and arrives by SCIM or in a `groups` claim at login. That is the
  invariant the whole design rests on and this does not touch it: Troupe still has no way
  to put a person in a team, only a way to say which of the provider's groups it listens
  to.

  `issuer` names the provider the group belongs to. One deployment has one today, and the
  column is here from the start so that a second is a migration rather than a redesign —
  the moment two providers both have a group called `engineering`, the pair is the
  identity and the name is not.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Plane.Identity.{Group, Team}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_group_links" do
    belongs_to(:team, Team)
    belongs_to(:group, Group)
    field(:issuer, :string)
    field(:linked_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:team_id, :group_id, :issuer, :linked_by])
    |> validate_required([:team_id, :group_id])
    |> unique_constraint([:team_id, :group_id])
  end
end
