defmodule Troupe.Plane.Repo.Migrations.TriggerCopies do
  @moduledoc """
  In direct mode an administrator may copy a `Trigger` resource from the plane's namespace
  into a row, and copy it again when the repository changes it. The row remembers what it
  was copied from and when, so that the console can say whether it is still what the
  repository says.

  `triggers.copied_from` is the resource's name (`<team>.<trigger>`) and
  `triggers.copied_generation` the resource's `metadata.generation` at the copy. Both are
  `NULL` for a row nobody copied. Neither is `resource_generation`, which a gitops pass
  writes and which makes a row go when its resource goes: a copy never goes by itself.
  """

  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add(:copied_from, :string)
      add(:copied_generation, :bigint)
    end
  end
end
