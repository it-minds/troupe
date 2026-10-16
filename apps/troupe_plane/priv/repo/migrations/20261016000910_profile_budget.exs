defmodule Troupe.Plane.Repo.Migrations.ProfileBudget do
  @moduledoc """
  A profile's own monthly ceiling on what its sessions spend, in millionths.

  `nil` is no ceiling, as a person's and a team's zero is. For a profile that extends
  another the column is the ceiling in effect, the lower of its own and its parent's, and
  what it wrote itself is in `own`, as for every other field a parent can give.

  No column on the ledger: what a profile spent is its sessions' charges, found through
  the session each charge names, which both tables already index.
  """

  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:budget_micros, :bigint)
    end
  end
end
