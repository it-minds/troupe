defmodule Troupe.Plane.Repo.Migrations.WorkerUpgradePending do
  @moduledoc """
  Which pod a worker is, and whether it runs an older revision than its StatefulSet's.

  The operator names the pods behind by name and uid, and a pod replaced under the same
  name is a different pod: the uid, from the enrolment token's own claim, is how the plane
  drains the one the operator meant and not its replacement. `upgrade_pending` is that
  answer kept for placement, which puts a new session on a pod that is current while one
  has room (Decision 726).
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add(:pod_uid, :string)
      add(:upgrade_pending, :boolean, null: false, default: false)
    end
  end
end
