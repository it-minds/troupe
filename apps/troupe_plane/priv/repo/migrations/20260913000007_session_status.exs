defmodule Troupe.Plane.Repo.Migrations.SessionStatus do
  @moduledoc """
  What a session is doing, without reading its log.

  Four lifecycle facts the worker reports on change — `status`, `done_reason`, how many
  approvals are pending, and the cost so far — so a review queue can be listed from the
  index. None of them says *what* the agent did: not the tool, not a word of any message.
  `origin` is what started the session and `terms` what it was allowed, both fixed at
  creation; `reviewed_by` and `reviewed_at` are a person closing the loop on a run
  nobody started by hand. All of it is rebuildable from `session_created` and
  `session_dormant` in object storage, so the index's claim to be an index stands.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:status, :string, null: false, default: "idle")
      add(:done_reason, :string)
      add(:pending_approvals, :integer, null: false, default: 0)
      add(:cost_micros, :bigint, null: false, default: 0)
      add(:origin, :map)
      add(:terms, :map)
      add(:reviewed_by, :string)
      add(:reviewed_at, :utc_datetime_usec)
    end

    create(index(:sessions, [:status, :last_active_at]))
    # The review queue asks for sessions by what started them, and a trigger's history
    # asks by which trigger. Expression indexes over the two keys, because the map is
    # small and fixed and a GIN index over the whole of it would be paying for questions
    # nobody asks.
    create(index(:sessions, ["(origin->>'kind')"], name: :sessions_origin_kind_index))
    create(index(:sessions, ["(origin->>'trigger')"], name: :sessions_origin_trigger_index))
  end
end
