defmodule Troupe.Plane.Repo.Migrations.SessionLifespan do
  @moduledoc """
  How long a session lasts (#1209): `throwaway`, erased by the plane a set time after it
  last worked; `normal`, today's; `persistent`, never cleared away by any sweep. Every row
  from before the column is `normal`, which is what every session was.

  It takes the place of `retention_class`, which the first sessions migration added and
  nothing ever read or wrote. That column is left where it is rather than renamed: the
  migration runs before the new plane's pods start, and a plane from before it selects
  `retention_class` with every session it reads, so a rename would fail every session
  read while the old pods still serve, and after a `helm rollback`. A later release drops
  it once no plane that names it can be running.

  Triggers and their revisions gain the same column, for the lifespan a trigger asks its
  runs' sessions to have.

  Additive only, so a plane from before it ignores the columns and a rollback keeps working.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:lifespan, :string, null: false, default: "normal")
    end

    create(
      constraint(:sessions, :sessions_lifespan_word,
        check: "lifespan IN ('throwaway', 'normal', 'persistent')"
      )
    )

    # What the plane's sweep asks every ten minutes: the throwaway sessions, oldest first.
    # Partial, because nearly every row is normal and never asked about.
    create(
      index(:sessions, [:last_active_at],
        where: "lifespan = 'throwaway'",
        name: :sessions_throwaway
      )
    )

    # A trigger may ask how long its runs' sessions last, and a revision keeps what it
    # asked; every trigger and revision from before it is normal.
    for table <- [:triggers, :trigger_revisions] do
      alter table(table) do
        add(:lifespan, :string, null: false, default: "normal")
      end

      create(
        constraint(table, :"#{table}_lifespan_word",
          check: "lifespan IN ('throwaway', 'normal', 'persistent')"
        )
      )
    end
  end
end
