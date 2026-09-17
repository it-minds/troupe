defmodule Troupe.Plane.Repo.Migrations.AuditChain do
  @moduledoc """
  A hash chain over the audit trail, so an altered row is an answerable question.

  The trail was a table of rows, and a table of rows is exactly as trustworthy as the
  database it is in: somebody who can write to PostgreSQL can change what an audit record
  says happened, and nothing would say so. The session log has been hash-chained since W1
  for that reason, over canonical JSON and excluding `prev_hash` so a verifier can
  recompute the chain from stored data alone. This is the same discipline over the same
  kind of claim.

  Both columns are nullable, and deliberately. A deployment upgrading into this migration
  has rows written before there was a chain, and rewriting them with hashes computed now
  would be the worst possible answer — a trail that *claims* to be verified back to its
  first row when nothing verified it. An unchained row is reported as unchained, the chain
  starts at the first row that has one, and the count of each is in the answer.

  `hash` is indexed because verification walks the trail in order and the repair somebody
  does afterwards is to find one row by its hash.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_events) do
      add(:hash, :string)
      add(:prev_hash, :string)
    end

    create(index(:audit_events, [:hash]))
  end
end
