defmodule Troupe.Plane.Repo.Migrations.GitopsTriggers do
  @moduledoc """
  In GitOps mode a trigger's row follows a `Trigger` resource a repository put in the
  cluster (Decision 737), as a profile's follows its `WorkerProfile` (736).

  `triggers.resource_generation` is the generation of the resource a row was last read
  from, and `NULL` for a row no resource has ever been read into. It tells a trigger whose
  resource the repository removed, which goes, from one the plane had before it was
  switched to GitOps, which is reported and kept. What the pass could not use goes in
  `gitops_reports`, which already takes any kind.
  """

  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add(:resource_generation, :integer)
    end
  end
end
