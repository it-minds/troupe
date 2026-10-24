defmodule Troupe.Plane.Repo.Migrations.GroupLastSeen do
  @moduledoc """
  When a group last arrived in somebody's sign-in (#765).

  A group the identity provider names in a token is made here at that sign-in, under the
  identifier the token carries, which for most providers is not the name a person knows it
  by. The console lists the groups that no team draws on with when each was last seen, so
  linking a new one is choosing a group the plane already knows rather than typing its
  identifier. Empty for a group only SCIM ever pushed, and for every group until its next
  sign-in.
  """

  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :last_seen_at, :utc_datetime_usec
    end
  end
end
