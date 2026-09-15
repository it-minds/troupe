defmodule Troupe.Plane.Repo.Migrations.GrantEntitlements do
  @moduledoc """
  A grant may name which of a bundle's agents, skills and servers a team gets.

  One child table on the grant we already have, rather than a second hierarchy. **No
  rows for a grant means no restriction**, which is exactly what every existing grant
  means today — so this migration changes nothing, needs no backfill, and the old
  behaviour is the default for a deployment that never opens the editor.

  Within a kind, `allow` rows are an allowlist and `deny` rows subtract; a kind with only
  `deny` rows is everything except those. Deny wins where both name the same thing,
  because the two ways of writing one intent must not disagree and the safe reading is
  the one that grants less.

  A name that is not in the current bundle is kept rather than pruned: a bundle can be
  rolled back, and an entitlement that vanished with a publish and did not come back with
  the revert would be a silent widening.
  """

  use Ecto.Migration

  def change do
    create table(:grant_entitlements, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:grant_id, references(:grants, type: :binary_id, on_delete: :delete_all), null: false)

      # "agent", "skill" or "mcp_server" — the three lists a bundle has. Not an enum
      # type: a fourth kind is a migration either way, and a check constraint says the
      # same thing without a type the schema has to keep in step with.
      add(:kind, :string, null: false)
      add(:name, :string, null: false)
      add(:mode, :string, null: false, default: "allow")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:grant_entitlements, [:grant_id, :kind, :name]))
    create(index(:grant_entitlements, [:grant_id]))

    create(
      constraint(:grant_entitlements, :grant_entitlements_kind,
        check: "kind in ('agent', 'skill', 'mcp_server')"
      )
    )

    create(
      constraint(:grant_entitlements, :grant_entitlements_mode,
        check: "mode in ('allow', 'deny')"
      )
    )
  end
end
