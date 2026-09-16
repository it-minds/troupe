defmodule Troupe.Plane.Identity.User do
  @moduledoc """
  A person, as the identity provider describes them.

  `subject` — the IdP's `sub` — is the identity. Email and display name are labels that
  change when people marry, move team, or correct a typo, and a system that keyed on
  either would lose track of them when they did.

  Nothing the *provider* owns is editable in Troupe. Users arrive by SCIM push or are
  created just in time at login, and both paths write the same row. `budget_micros` is
  the exception and is deliberately not among them: a spend ceiling is Troupe's opinion
  about somebody, not the provider's, and a SCIM push that reset it every night would be
  a cap that lasted until the next sync.

  A service principal is handed around as one of these too, with `kind: "service"` and
  no row behind it: `id` is nil and `principal` carries the record. Everything that
  answers "what may this caller do" — grants, teams, visibility — takes a `%User{}`, and
  a principal that were a second struct would need a second copy of every one of those
  functions. The two virtual fields are the whole of the difference.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:subject, :string)
    field(:external_id, :string)
    field(:email, :string)
    field(:display_name, :string)
    field(:active, :boolean, default: true)

    # This person's own spend ceiling, in millionths, across every team they are in.
    # Zero and `nil` both mean no ceiling: somebody who has never been given one should
    # not be unable to work.
    field(:budget_micros, :integer)

    # `"user"` for a person, `"service"` for a principal; never persisted, because a
    # principal has its own table and a person's kind is implied by having a row here.
    field(:kind, :string, virtual: true, default: "user")
    field(:principal, :any, virtual: true)

    many_to_many(:groups, Troupe.Plane.Identity.Group,
      join_through: Troupe.Plane.Identity.Membership,
      on_replace: :delete
    )

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

  @doc """
  Set or clear this person's own ceiling.

  Separate from `changeset/2` on purpose: that one is what SCIM and a login write, and a
  cap that could arrive through the same door would be a cap the next provider push
  silently reset.
  """
  @spec budget_changeset(t(), map()) :: Ecto.Changeset.t()
  def budget_changeset(user, attrs) do
    user
    |> cast(attrs, [:budget_micros])
    |> validate_number(:budget_micros, greater_than_or_equal_to: 0)
  end
end
