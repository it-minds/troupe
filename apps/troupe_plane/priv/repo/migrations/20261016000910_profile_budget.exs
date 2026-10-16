defmodule Troupe.Plane.Repo.Migrations.ProfileBudget do
  @moduledoc """
  A profile's own monthly ceiling on what its sessions spend, in millionths.

  `nil` is no ceiling, as a person's and a team's zero is. For a profile that extends
  another the column is the ceiling in effect, the lower of its own and its parent's, and
  what it wrote itself is in `own`, as for every other field a parent can give.

  No column on the ledger: what a profile spent is its sessions' charges, found through
  the session each charge names, which both tables already index.

  `own_servers` is the MCP servers a profile that extends nothing was written with itself,
  apart from the ones its bundle gives it: the spec's `mcpServers` is both together, as
  its pods load them, and a publish composes the two again rather than overwriting the
  profile's own. `nil` for a row written before there was the column, whose own servers
  are the spec's that its channel's bundle does not name. A profile that extends another
  keeps its own in `own`.
  """

  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:budget_micros, :bigint)
      add(:own_servers, {:array, :map})
    end
  end
end
