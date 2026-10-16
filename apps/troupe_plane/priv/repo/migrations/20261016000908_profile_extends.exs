defmodule Troupe.Plane.Repo.Migrations.ProfileExtends do
  @moduledoc """
  A profile may extend one other profile.

  `extends` names the parent. `own` is what the profile's administrator wrote, kept as it
  was written, because the row's other columns and its `spec` become the profile in
  effect: the parent's, with this one's laid over it. Without `own` a change to the parent
  could not be told apart from a value the child set itself, and the child would stop
  following its parent the first time it was saved.

  No foreign key: a profile that others extend is refused deletion by the plane with a
  sentence naming them, which a constraint error could not say, and a plane in gitops mode
  reads rows that extend nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:extends, :string)
      add(:own, :map)
    end

    create(index(:profiles, [:extends]))
  end
end
