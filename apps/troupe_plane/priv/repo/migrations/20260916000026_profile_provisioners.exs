defmodule Troupe.Plane.Repo.Migrations.ProfileProvisioners do
  @moduledoc """
  Which substrate a profile's workers come from.

  A string rather than a module name, because the row outlives any particular module and a
  profile that named one would stop loading when somebody renamed it. `kubernetes` for
  every profile that already exists, which is what they all are and what a profile created
  by something that does not know the question should be.

  There is deliberately no `unenforced` column beside it. What a substrate guarantees is a
  property of the substrate, not a field somebody can edit — a profile row that said it was
  enforced would be a claim the cluster had never made, and the one place it could be wrong
  is the place it matters most.
  """

  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:provisioner, :string, null: false, default: "kubernetes")
    end

    create(
      constraint(:profiles, :profiles_provisioner,
        check: "provisioner in ('kubernetes', 'ssh')"
      )
    )
  end
end
