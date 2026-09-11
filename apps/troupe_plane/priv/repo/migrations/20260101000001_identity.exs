defmodule Troupe.Plane.Repo.Migrations.Identity do
  @moduledoc """
  Who exists, and what they belong to.

  Users and groups come from the identity provider and are never edited in Troupe:
  either SCIM pushes them, or they are created just in time from the groups claim at
  login. A *team* is the one thing Troupe adds — an IdP group that a platform admin has
  enabled — and even then its membership still comes from the IdP.
  """

  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # The IdP's `sub`. Stable across renames and email changes, which is why it is
      # the identity rather than the address.
      add :subject, :string, null: false
      add :external_id, :string
      add :email, :string
      add :display_name, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:subject])
    create index(:users, [:email])

    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :string, null: false
      add :display_name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:groups, [:external_id])

    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:user_id, :group_id])
    create index(:memberships, [:group_id])

    create table(:teams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # A team is a group somebody enabled. One group, one team.
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :enabled_at, :utc_datetime_usec
      add :enabled_by, :string

      # Whether team visibility grants control as well as observe.
      add :members_may_control, :boolean, null: false, default: false

      # Retention, per team. Defaults match the spec's.
      add :idle_timeout_seconds, :integer, null: false, default: 1800
      add :cache_eviction_days, :integer, null: false, default: 7
      add :erase_after_days, :integer, null: false, default: 365
      add :pins_allowed, :boolean, null: false, default: true

      # Spend, in micro-units of currency so a reservation never rounds.
      add :budget_micros, :bigint, null: false, default: 0
      add :budget_period, :string, null: false, default: "monthly"

      add :volume_storage_class, :string
      add :volume_size, :string, null: false, default: "10Gi"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:teams, [:group_id])
    create unique_index(:teams, [:name])

    create table(:grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      add :profile, :string, null: false
      add :role, :string, null: false, default: "use"
      # How the team's volume is mounted in this profile's pods.
      add :volume_mode, :string, null: false, default: "ro"
      add :granted_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:grants, [:team_id, :profile])
    create index(:grants, [:profile])
  end
end
