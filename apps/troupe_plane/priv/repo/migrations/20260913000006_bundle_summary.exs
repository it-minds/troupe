defmodule Troupe.Plane.Repo.Migrations.BundleSummary do
  @moduledoc """
  What a bundle carries, without opening it.

  A bundle document may be four megabytes of agent prompts and skill files, and a list
  of a channel's versions should not decode every one of them to say how many agents
  each has. The summary — counts and names — is written at publish and never changes,
  because the version it describes never does. Rows published before this column
  existed keep an empty map, which the panel shows as "summarised by an older plane"
  rather than pretending they carry nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:config_bundles) do
      add(:summary, :map, null: false, default: %{})
    end
  end
end
