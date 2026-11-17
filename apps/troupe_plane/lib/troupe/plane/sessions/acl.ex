defmodule Troupe.Plane.Sessions.ACL do
  @moduledoc """
  Who may see a session, beside its owner and its team.

  This table is the record: `session.grant` and an invitation write a row, taking the
  invitation back deletes it, and each change is pushed to the pod holding the session
  (`acl.changed`), whose mirror is fed by nothing else. "The sessions I can see" is one
  query over it. A rebuild of the index from object storage does not touch it: like the
  rest of the grants, it comes back from a backup of the database.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner collaborator viewer)

  schema "session_acls" do
    field :session_id, :string
    field :subject, :string
    field :role, :string
    field :granted_by, :string
    field :granted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  The roles, and the scopes they map to.

  Owner administers, collaborator steers, viewer watches — the same three scopes the
  protocol uses everywhere else, so an ACL entry needs no translation at the connection.
  """
  @spec scope(String.t()) :: :admin | :control | :observe
  def scope("owner"), do: :admin
  def scope("collaborator"), do: :control
  def scope(_), do: :observe

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(acl, attrs) do
    acl
    |> cast(attrs, [:session_id, :subject, :role, :granted_by, :granted_at])
    |> validate_required([:session_id, :subject, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:session_id, :subject])
  end
end
