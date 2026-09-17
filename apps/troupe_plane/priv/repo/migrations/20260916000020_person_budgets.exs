defmodule Troupe.Plane.Repo.Migrations.PersonBudgets do
  @moduledoc """
  A ceiling that is a person's, and a reservation that knows whose it is.

  A cap belonged to a team and to nothing else, so the two things people actually ask
  for — "this contractor may spend a hundred a month" and "nobody may spend more than
  this whatever team they are in" — had no way to be said. `users.budget_micros` is the
  person's own, in the same millionths and with the same meaning for zero: no limit,
  because a person who has not been given a cap should not be unable to work.

  `budget_reservations.owner_subject` is what makes a person's outstanding promises
  addable. The table already had the team; a reservation that did not say whose it was
  could be summed for a team and not for anybody in it, and a cap you cannot count
  against is a cap that does not exist.

  Backfilled from the session that made each reservation. A row whose session is gone
  keeps a null subject and counts against nobody, which is the honest answer: the
  session it belonged to has been erased and there is nothing left to attribute it to.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:budget_micros, :bigint)
    end

    alter table(:budget_reservations) do
      add(:owner_subject, :string)
    end

    execute("""
    UPDATE budget_reservations AS r
       SET owner_subject = s.owner_subject
      FROM sessions AS s
     WHERE s.id = r.session_id
    """)

    # Open reservations only: the sum a cap is checked against never looks at released
    # ones, and an index that carried them would grow forever behind a query that does
    # not read them.
    create(
      index(:budget_reservations, [:owner_subject],
        where: "released_at IS NULL",
        name: :budget_reservations_open_by_owner
      )
    )

    create(index(:usage_records, [:owner_subject, :occurred_at]))
  end

  def down do
    drop(index(:usage_records, [:owner_subject, :occurred_at]))
    drop(index(:budget_reservations, [:owner_subject], name: :budget_reservations_open_by_owner))

    alter table(:budget_reservations) do
      remove(:owner_subject)
    end

    alter table(:users) do
      remove(:budget_micros)
    end
  end
end
