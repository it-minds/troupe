defmodule Troupe.Plane.Sessions.Share do
  @moduledoc """
  A capability over a session: a link that carries a role rather than a name.

  The ACL answers *who is allowed here*, by subject, and it is the right answer whenever
  the person has an account. A share answers the question people actually ask — *send them
  this* — and folding one into the other would break both. An ACL entry for somebody who
  has never signed in is a row waiting for a subject that may never arrive; a capability
  with no end is an ACL entry nobody remembers granting.

  ## Refused at mint, never at use

  Everything about what this capability *may* carry is decided when it is made: that the
  person minting it has the session, that the role does not exceed what they hold, that
  the expiry is inside the ceiling. None of it is asked again. A link that re-derived its
  authority from the sharer at every use would silently stop working when they changed
  teams, which is not what anybody means by sending somebody a link — and it would make
  what a recipient can see depend on something they cannot see.

  What *is* checked at redemption is only whether this capability still exists: unexpired,
  unrevoked, and for them if it named them. Those are facts about the share itself.

  ## Never `admin`

  `observe` or `control`, and the database says so too. A capability that could administer
  a session could mint further capabilities, and a link that can mint links is a link
  nobody can reason about — not the person who sent it, and not the person auditing it
  afterwards.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  @roles ~w(observe control)

  schema "session_shares" do
    field(:session_id, :string)
    field(:role, :string)

    field(:secret_hash, :string)
    field(:secret_salt, :string)

    field(:created_by, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:audience, :string)

    field(:revoked_at, :utc_datetime_usec)
    field(:revoked_by, :string)
    field(:revoked_reason, :string)

    field(:redeemed_count, :integer, default: 0)
    field(:last_redeemed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The two roles a share may carry. `admin` is not one of them, and never will be."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc """
  The scope this share hands its holder.

  The same three scopes everything else uses, so a redeemed share needs no translation at
  the connection — it becomes an ordinary session token at an ordinary role.
  """
  @spec scope(t() | String.t()) :: :control | :observe
  def scope(%__MODULE__{role: role}), do: scope(role)
  def scope("control"), do: :control
  def scope(_observe), do: :observe

  @doc "The ACL role name a redeemed share presents as."
  @spec role_name(t() | String.t()) :: String.t()
  def role_name(%__MODULE__{role: role}), do: role_name(role)
  def role_name("control"), do: "collaborator"
  def role_name(_observe), do: "viewer"

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(share, attrs) do
    share
    |> cast(attrs, [
      :id,
      :session_id,
      :role,
      :secret_hash,
      :secret_salt,
      :created_by,
      :expires_at,
      :audience
    ])
    |> validate_required([
      :id,
      :session_id,
      :role,
      :secret_hash,
      :secret_salt,
      :created_by,
      :expires_at
    ])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:secret_hash)
    |> check_constraint(:role, name: :session_shares_role)
  end

  @spec revoke_changeset(t(), map()) :: Ecto.Changeset.t()
  def revoke_changeset(share, attrs) do
    cast(share, attrs, [:revoked_at, :revoked_by, :revoked_reason])
  end

  @doc """
  Whether this capability is still one, at `now`.

  Three facts about the share and nothing about the person who made it. That is the whole
  of what redemption asks.
  """
  @spec live?(t(), DateTime.t()) :: boolean()
  def live?(%__MODULE__{revoked_at: revoked}, _now) when not is_nil(revoked), do: false

  def live?(%__MODULE__{expires_at: expires}, now),
    do: DateTime.compare(expires, now) == :gt

  @doc "Why this share is not usable, for somebody looking at a listing."
  @spec state(t(), DateTime.t()) :: String.t()
  def state(%__MODULE__{revoked_at: revoked}, _now) when not is_nil(revoked), do: "revoked"

  def state(%__MODULE__{} = share, now) do
    if live?(share, now), do: "live", else: "expired"
  end
end
