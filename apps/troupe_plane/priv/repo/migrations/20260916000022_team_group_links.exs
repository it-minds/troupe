defmodule Troupe.Plane.Repo.Migrations.TeamGroupLinks do
  @moduledoc """
  A team *links* to groups instead of being one.

  "A team is an identity-provider group somebody enabled" was one group, one team, for
  ever, and the team had no identity of its own. That rigidity is what made "assign users
  to a profile" look necessary: if the only team you can have is the group your provider
  happens to hold, the shape of your access control is somebody else's org chart.

  Three shapes become sayable, and all three are things people ask for:

  * **1:1** — `itm-backend` to **Backend**. The common case, and what every existing team
    becomes.
  * **2:1** — `itm-backend` and `itm-platform` to **Engineering**. Small groups in the
    provider, joined into one team here, which is cheaper than asking IT for a group every
    time a grant needs a different shape.
  * **1:2** — `itm-consultants` to **Delivery** and **Timesheets**. One group, two teams,
    with their own budgets, retention and grants.

  **The invariant is untouched.** "Membership always comes from the provider and is never
  edited in Troupe" said *derived, not typed*. It is still derived — from a union of
  groups instead of from one. Nobody adds a person to a team here; they add a group, and
  the provider decides who is in it.

  ## The issuer is carried from the start

  `issuer` on a link is the identity provider the group belongs to, and it is here now
  rather than later because a second provider should be a migration and not a redesign.
  Every existing link takes the deployment's own issuer, which is what it has always
  implicitly meant.

  ## Every existing team becomes one link

  Backfilled from `teams.group_id`, so resolved membership is identical either side of
  this and a deployment that never uses N:M sees no change at all. `teams.group_id` stays
  for now — dropping a column is not the same operation as not reading one, and a
  migration that did both would have nothing to roll back to.
  """

  use Ecto.Migration

  def up do
    create table(:team_group_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false)
      add(:group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false)

      # Which provider the group belongs to. One deployment, one issuer, today — and a
      # column that exists from the start is a second provider's migration rather than its
      # redesign.
      add(:issuer, :string)

      add(:linked_by, :string)
      timestamps(type: :utc_datetime_usec)
    end

    # One link per pair. Linking a group twice is the same link, not a person counted
    # twice — which matters because membership is a union and a union over duplicates is
    # a listing with everybody in it twice.
    create(unique_index(:team_group_links, [:team_id, :group_id]))
    create(index(:team_group_links, [:group_id]))

    execute("""
    INSERT INTO team_group_links (id, team_id, group_id, linked_by, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.id, t.group_id, 'migration:team_group_links', now(), now()
      FROM teams AS t
     WHERE t.group_id IS NOT NULL
    """)
  end

  def down do
    drop(table(:team_group_links))
  end
end
