defmodule Troupe.Plane.Repo.Migrations.Sessions do
  @moduledoc """
  The session index: metadata only, and rebuildable.

  Every column here is something a listing needs — who owns it, which team it belongs
  to, what state it is in, how big it has got. None of it is session *content*, and a
  done item proves that: a marker string sent as session input must not appear in a
  dump of this database.

  It can be rebuilt from the manifests in object storage, which is what
  `troupe admin index rebuild` does, so losing it costs a rebuild rather than the
  sessions.
  """

  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      # The session id the worker generated. Not a surrogate key: it appears in object
      # keys, in tokens, and in the log, and a second identifier would be a second
      # thing to keep in step.
      add :id, :string, primary_key: true
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :owner_subject, :string, null: false
      add :team_id, references(:teams, type: :binary_id, on_delete: :nilify_all)
      add :profile, :string, null: false
      add :visibility, :string, null: false, default: "private"
      add :state, :string, null: false, default: "active"

      # Epochs are minted here and nowhere else. A segment key carries the epoch it was
      # written under, so a pod that comes back from the dead cannot append to a
      # session that has moved on.
      add :epoch, :integer, null: false, default: 1
      add :worker_id, references(:workers, type: :binary_id, on_delete: :nilify_all)

      add :title, :string
      add :workspace_source, :map
      add :bundle_version, :integer
      add :retention_class, :string
      add :pinned, :boolean, null: false, default: false
      add :pinned_by, :string
      add :pinned_at, :utc_datetime_usec

      add :last_active_at, :utc_datetime_usec
      add :last_seq, :integer, null: false, default: 0
      add :head_hash, :string
      add :object_bytes, :bigint, null: false, default: 0
      add :workspace_bytes, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:owner_id])
    create index(:sessions, [:team_id, :visibility])
    create index(:sessions, [:profile, :state])
    create index(:sessions, [:worker_id, :state])
    create index(:sessions, [:state, :last_active_at])

    # A mirror of the ACL events in the session log. The log is the source of truth;
    # this is what makes "the sessions I can see" one query.
    create table(:session_acls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false
      add :subject, :string, null: false
      add :role, :string, null: false
      add :granted_by, :string
      add :granted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_acls, [:session_id, :subject])
    create index(:session_acls, [:subject])

    # Sealed segment heads, which double as audit anchors: the plane holds a hash of
    # the log at a point the worker sealed, so tampering with stored events is
    # detectable without trusting the storage.
    create table(:anchors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false
      add :epoch, :integer, null: false
      add :first_seq, :integer, null: false
      add :last_seq, :integer, null: false
      add :head_hash, :string, null: false
      add :object_key, :string, null: false
      add :bytes, :bigint, null: false, default: 0
      add :sealed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:anchors, [:session_id, :epoch, :last_seq])
    create index(:anchors, [:session_id, :last_seq])

    # What is left of an erased session, and all that may be left.
    create table(:tombstones, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :head_hash, :string
      add :reason, :string, null: false
      add :actor, :string, null: false
      add :erased_at, :utc_datetime_usec, null: false
      # Pods that were offline when this ran apply it when they enrol, before serving
      # anything, and this is how they learn what to apply.
      add :applied_by, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tombstones, [:session_id])
  end
end
