defmodule Troupe.Plane.Repo.Migrations.ServicePrincipals do
  @moduledoc """
  A credential a team owns, for work nobody starts by hand.

  Not a user and not a member: a principal is created *by* a team admin *for* a team,
  the way `team_admins` records a role a team assigns inside Troupe, and membership
  stays the identity provider's business. It may use a subset of the team's grants and
  nothing else, and `Admin` gives it no role at all.

  The secret is generated here, shown once, and stored only as a salted hash. There is
  no key-derivation dependency in this release, so the hash is SHA-256 over a random
  salt and the secret; the secret has 256 bits of entropy, which is what makes that
  acceptable where it would not be for a password.
  """

  use Ecto.Migration

  def change do
    create table(:service_principals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      # `svc:<team>/<name>`, which is what appears as `owner_subject` on every session it
      # creates and as the actor on every input in their logs.
      add(:subject, :string, null: false)
      add(:team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:description, :string)
      add(:profiles, {:array, :string}, null: false, default: [])
      add(:secret_hash, :string, null: false)
      add(:secret_salt, :string, null: false)
      add(:created_by, :string)
      add(:disabled_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:service_principals, [:subject]))
    create(unique_index(:service_principals, [:team_id, :name]))
  end
end
