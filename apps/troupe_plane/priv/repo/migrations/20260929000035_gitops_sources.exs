defmodule Troupe.Plane.Repo.Migrations.GitopsSources do
  @moduledoc """
  In GitOps mode the plane's rows follow resources a repository put in the cluster
  (Decision 736), and two things have to be remembered for that.

  `profiles.resource_generation` is the generation of the `WorkerProfile` a row was last
  read from, and `NULL` for a row no resource has ever been read into. It is what tells a
  profile whose resource the repository removed, which goes, from a row the plane had
  before it was switched to GitOps and the cluster never had, which is reported and kept.

  `gitops_reports` is what the plane read and could not use: a resource that fails the
  plane's own checks, a row with no resource, a resource only the plane has ever written.
  By kind and name, so another kind of resource reports into the same table, and in the
  database rather than in the process that reads the cluster, because that process is one
  replica's and the console asking is any replica's.
  """

  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:resource_generation, :integer)
    end

    create table(:gitops_reports, primary_key: false) do
      add(:kind, :string, primary_key: true)
      add(:name, :string, primary_key: true)
      add(:problem, :string, null: false)
      add(:generation, :integer)
      add(:reasons, {:array, :string}, null: false, default: [])

      timestamps(type: :utc_datetime_usec)
    end
  end
end
