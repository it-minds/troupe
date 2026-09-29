defmodule Troupe.Plane.Repo.Migrations.WorkerRetiring do
  @moduledoc """
  Whether a pod is draining because the scaler is removing it.

  A scale-down drains the pods above the new count and lowers the count only once they
  hold nothing (Decision 731). If the sessions come back while they drain, the count still
  comes down past them, because a drained pod takes no session until it restarts; this is
  how the scaler tells its own drain from an administrator's, which it leaves alone.
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add(:retiring, :boolean, null: false, default: false)
    end
  end
end
