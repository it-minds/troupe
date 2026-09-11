defmodule Troupe.Plane.Identity.TeamAdmin do
  @moduledoc """
  Somebody a platform admin has made an administrator of one team.

  The only role Troupe assigns. `platform_admin` comes from an identity-provider group,
  because an admin role Troupe could grant would be a way to escalate inside Troupe; a
  team admin is deliberately narrower — one team, and no ability to create more of
  themselves.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_admins" do
    belongs_to :team, Troupe.Plane.Identity.Team
    field :subject, :string
    field :granted_by, :string
    field :granted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:team_id, :subject, :granted_by, :granted_at])
    |> validate_required([:team_id, :subject, :granted_by, :granted_at])
    |> unique_constraint([:team_id, :subject])
  end
end
