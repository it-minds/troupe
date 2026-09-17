defmodule Troupe.Plane.Repo.Migrations.AcpAgentEntitlements do
  @moduledoc """
  A fourth kind a grant can narrow: a third-party agent run as a subprocess.

  The original migration said a fourth kind would be a migration either way, and that the
  check constraint says which four rather than leaving it to application code. This is that
  migration, and the constraint is replaced rather than dropped — a column that would take
  any string is a column where a typo becomes an entitlement nobody granted and nobody can
  find.

  Nothing is backfilled. Absence means everything, so a grant with no `acp_agent` rows
  allows every ACP agent the bundle has, which is the same rule the other three kinds
  follow and the only one that does not change what an existing team can do.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:grant_entitlements, :grant_entitlements_kind))

    create(
      constraint(:grant_entitlements, :grant_entitlements_kind,
        check: "kind in ('agent', 'skill', 'mcp_server', 'acp_agent')"
      )
    )
  end

  def down do
    # A row of the new kind would fail the old constraint, so it goes first. Deleting is
    # right rather than harsh: rolling back is saying this kind does not exist, and a row
    # naming a kind nothing reads is an entitlement that silently stops applying.
    execute("DELETE FROM grant_entitlements WHERE kind = 'acp_agent'")

    drop(constraint(:grant_entitlements, :grant_entitlements_kind))

    create(
      constraint(:grant_entitlements, :grant_entitlements_kind,
        check: "kind in ('agent', 'skill', 'mcp_server')"
      )
    )
  end
end
