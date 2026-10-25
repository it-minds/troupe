defmodule Troupe.Plane.Repo.Migrations.SessionInvites do
  @moduledoc """
  A person invites another into their session by name (#765).

  `session_invites` is one row per session and invitee: whom, at which role (`observe` or
  `control`), who invited them and when. A pod session's invitation is its ACL row made
  visible; the row is what the invitee's list and the session's head read. Removing the
  invitation deletes the row, and the audit trail keeps that it was there.

  `session_invite_keys` is where a private session's key was put for one invitee: one row
  per key the session has been sealed under, the path in the invitee's own slot at the key
  manager where the owner's machine put it. The plane holds the path, can destroy what is
  there, and cannot read it.

  `sessions.key_version` is how many keys a private session has been sealed under: one,
  and one more each time an invitation is taken back. `rekey_due` says one was taken back
  and the owner's machine has not yet sealed under a new key.
  """

  use Ecto.Migration

  def change do
    create table(:session_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false
      add :subject, :string, null: false
      add :role, :string, null: false
      add :invited_by, :string, null: false
      add :invited_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_invites, [:session_id, :subject])
    create index(:session_invites, [:subject])

    create table(:session_invite_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false
      add :subject, :string, null: false
      add :key_version, :integer, null: false
      add :slot, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_invite_keys, [:session_id, :subject, :key_version])

    alter table(:sessions) do
      add :key_version, :integer, null: false, default: 1
      add :rekey_due, :boolean, null: false, default: false
    end
  end
end
