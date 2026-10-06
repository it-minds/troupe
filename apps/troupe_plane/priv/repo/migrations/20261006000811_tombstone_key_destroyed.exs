defmodule Troupe.Plane.Repo.Migrations.TombstoneKeyDestroyed do
  @moduledoc """
  When the plane destroyed an erased session's key (Decision 811).

  The plane now destroys a team session's key itself, as it does a private one's. Before
  this a pod of the profile was asked to, and the credential an installation gives a pod
  may destroy no key, so a team session erased before this release may still have one.
  The column says which keys the plane has destroyed: empty on every tombstone written
  before, so the plane's erasure pass destroys each of those once, after the upgrade, and
  set when it has. A key already gone counts as destroyed.

  Only the column here. The destroying is the running plane's, with its own credential:
  this runs in the chart's pre-upgrade job, which has none, and an upgrade must not wait
  on the key manager answering.
  """

  use Ecto.Migration

  def change do
    alter table(:tombstones) do
      add(:key_destroyed_at, :utc_datetime_usec)
    end
  end
end
