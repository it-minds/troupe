defmodule Troupe.Plane.Repo.Migrations.UsageWatermark do
  @moduledoc """
  How far the ledger has got through each session's log.

  `usage_seq` is the highest log sequence whose model calls are recorded in
  `usage_records` for that session. It is what a batch's reply carries back, and it is
  the only state a pod needs in order to know what it still owes: everything above it is
  either still in the pod's table or foldable out of the log again.

  Not a new source of truth. A pod's log is what happened and `usage_records` is what was
  charged; this is a cursor between them, and a cursor that is behind costs a re-fold and
  a handful of duplicate inserts the unique index throws away.

  One column and no indexes: the two the ledger's aggregates want —
  `(team_id, occurred_at)` and `(session_id)` — were already created with the table in
  `20260101000004_ledger_and_audit`.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:usage_seq, :bigint, null: false, default: 0)
    end
  end
end
