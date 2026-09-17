defmodule Troupe.Plane.Repo.Migrations.PrivateSessions do
  @moduledoc """
  A session that belongs to a person rather than to a team.

  A private session runs on somebody's laptop, is sealed with a key only they can read,
  and never touches a worker. The plane holds the row so a second device can find it —
  sizes, sequence numbers, hashes, and nothing else.

  `kind` is a new column rather than a reuse of `visibility`. They answer different
  questions: `visibility` is who else on the team may see a session, and its default is
  already `private`, so a team session with no sharing is *visibility private* and has
  been since the first migration. Overloading it would have made "the private sessions"
  a query that silently included every unshared team session.

  The constraint is the point of the migration. A private session has no team and no
  profile, and a team session has a profile; both halves are true of every row today
  and neither is enforceable in application code alone, because the row is what a
  placement reads.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :kind, :string, null: false, default: "team"
      # Where a laptop last sealed from, for a listing that has to say which device is
      # holding a session and which one lost the fence.
      add :device, :string
    end

    # A private session has no profile to run on. Every existing row is a team session
    # and keeps its own.
    execute "ALTER TABLE sessions ALTER COLUMN profile DROP NOT NULL"

    create constraint(:sessions, :sessions_kind_shape,
             check: """
             (kind = 'team' AND profile IS NOT NULL)
             OR (kind = 'private' AND profile IS NULL AND team_id IS NULL AND worker_id IS NULL)
             """
           )

    # The listing a second device asks for: mine, private, most recent first.
    create index(:sessions, [:owner_subject, :kind, :last_active_at])
  end

  def down do
    drop index(:sessions, [:owner_subject, :kind, :last_active_at])
    drop constraint(:sessions, :sessions_kind_shape)

    execute "DELETE FROM sessions WHERE kind = 'private'"
    execute "ALTER TABLE sessions ALTER COLUMN profile SET NOT NULL"

    alter table(:sessions) do
      remove :device
      remove :kind
    end
  end
end
