defmodule Troupe.Plane.Repo.Migrations.AuditOnBehalfOf do
  @moduledoc """
  On whose authority, beside who did it.

  `actor` has always been the thing that made the call. `on_behalf_of` is whose authority
  it was made under, and the two differ exactly when the interesting things happen: a
  trigger firing as a principal on a sponsor's authority, a delegated MCP call going out
  with somebody else's credential.

  Written even when they match. A column that is null when the two are equal is a column
  a reader cannot interpret — null because they were the same, or null because that day's
  code did not fill it in, are not distinguishable once the rows are a year old. The
  backfill says so for every row that already exists: whatever the actor was, it was also
  the authority, because there was no other kind of row.
  """

  use Ecto.Migration

  def up do
    alter table(:audit_events) do
      add :on_behalf_of, :string
    end

    execute "UPDATE audit_events SET on_behalf_of = actor WHERE on_behalf_of IS NULL"

    # "Everything this person is answerable for" is the question a leaver's review asks,
    # and it is asked of the authority rather than of the actor.
    create index(:audit_events, [:on_behalf_of, :occurred_at])
  end

  def down do
    drop index(:audit_events, [:on_behalf_of, :occurred_at])

    alter table(:audit_events) do
      remove :on_behalf_of
    end
  end
end
