defmodule Troupe.Plane.Repo.Migrations.RemoteGrants do
  @moduledoc """
  A laptop's daemon keeps its own sign-in while a session is offered (#58 slice 2).

  `remote_grants` is one row per person and device: the hash of the secret the daemon
  holds in its operating system's credential store, which it exchanges at `/auth/relay`
  for a token that opens the laptop's door (`/v1/relay`) and nothing else. Never the
  secret itself. Withdrawing the last offer, signing out, or `troupe logout` deletes the
  row.

  `teams.remote_offering_allowed` is the team administrators' switch: off, and none of the
  team's people may offer a laptop session for steering from another device.
  """

  use Ecto.Migration

  def change do
    create table(:remote_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject, :string, null: false
      add :device, :string, null: false
      add :secret_hash, :binary, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:remote_grants, [:subject, :device])

    alter table(:teams) do
      add :remote_offering_allowed, :boolean, null: false, default: true
    end
  end
end
