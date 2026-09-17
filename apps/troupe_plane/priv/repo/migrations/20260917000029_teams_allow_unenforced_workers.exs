defmodule Troupe.Plane.Repo.Migrations.TeamsAllowUnenforcedWorkers do
  @moduledoc """
  Whether this team may be placed on a profile whose substrate does not enforce.

  An SSH worker is outside Kubernetes, and the guarantees Kubernetes was providing —
  admission policy, NetworkPolicy, FQDN egress, a disruption budget — are simply not there.
  That is not a footnote. A team runs on such a profile only where a platform admin has
  said so for that team, by name, and the grant is refused with the missing guarantees
  listed until they have.

  `false` for every team that exists and for every team made afterwards, which is the only
  default a flag like this may have: absence means everything, so absence here has to mean
  the safe reading rather than the convenient one. A deployment that upgrades into this
  migration grants nothing it did not grant yesterday.

  It is deliberately not on the settings ladder. A platform-wide switch would be one value
  that turned the friction off everywhere, and the friction is the feature — the whole
  point is that somebody decides per team, in the audit trail, with the list of what is
  missing in front of them.
  """

  use Ecto.Migration

  def change do
    alter table(:teams) do
      add(:allow_unenforced_workers, :boolean, null: false, default: false)
    end
  end
end
