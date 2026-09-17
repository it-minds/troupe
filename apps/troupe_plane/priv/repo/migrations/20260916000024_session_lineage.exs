defmodule Troupe.Plane.Repo.Migrations.SessionLineage do
  @moduledoc """
  Where a session came from, on the row, so a tree draws without opening a log.

  The lineage is already in the log: `session_forked` is the child's first event and
  carries the parent's id, the seq forked at and the parent's head hash there. That is the
  record. This is the projection — because drawing "what came from this session" in a
  listing would otherwise mean fetching a key, opening a segment and decrypting the first
  event of every session on the page, which is three things a listing must not do.

  `ON DELETE SET NULL` is the load-bearing part. A parent may be erased, and erasing it
  must leave the child readable — the child's events are its own copies under its own key,
  so the only thing that can break is this pointer, and it becomes `NULL` rather than
  taking the child with it. A child whose parent is gone is a session with an unknown
  origin, which is true and is not an error.

  `parent_seq` stays whatever it was. It records the point in a chain that no longer
  exists, which is still the honest answer to "where did this come from", and a reader can
  tell the difference between "forked from nothing" and "forked at 40 from something since
  erased" only if the number survives.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:parent_session_id, references(:sessions, type: :string, on_delete: :nilify_all))
      add(:parent_seq, :integer)
      add(:fork_reason, :string)
    end

    # Children of one parent, which is the query a lineage view makes and the one an
    # erasure makes when it goes looking for what it must not take with it.
    create(index(:sessions, [:parent_session_id]))
  end
end
