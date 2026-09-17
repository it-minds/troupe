defmodule Troupe.Plane.Repo.Migrations.TeamsAreNotGroups do
  @moduledoc """
  One group may be two teams.

  `teams.group_id` had a unique index, which is the 1:1 assumption written into the
  database: one group, one team, for ever. It is exactly what stopped a consultancy
  saying "these contractors are Delivery for the grants and Timesheets for the budget",
  which is a thing people ask for and a thing the links table now makes sayable.

  The **name** stays unique, because that is what a team is addressed by everywhere — a
  grant, a session's team, an audit row — and two teams called `engineering` would be two
  answers to one question.

  The column stays. It records which group a team was first enabled from, which is worth
  keeping and is no longer what membership is derived from; `team_group_links` is. Dropping
  a column is not the same operation as not reading one, and doing both at once would
  leave nothing to roll back to.
  """

  use Ecto.Migration

  def up do
    drop(unique_index(:teams, [:group_id]))
    create(index(:teams, [:group_id]))
  end

  def down do
    drop(index(:teams, [:group_id]))
    create(unique_index(:teams, [:group_id]))
  end
end
