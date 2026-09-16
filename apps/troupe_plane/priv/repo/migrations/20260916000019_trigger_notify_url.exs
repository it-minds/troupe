defmodule Troupe.Plane.Repo.Migrations.TriggerNotifyUrl do
  @moduledoc """
  Where a trigger tells somebody else's system that a run finished.

  Nullable and absent by default, because a trigger that announces nothing is the common
  case and a column with a default would be a target nobody chose. What may go in it is
  `Troupe.Plane.Triggers.Notify`'s business and is checked at save and again at send —
  the column itself holds a string, and a database constraint could not tell a loopback
  hostname from any other.
  """

  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add(:notify_url, :string)
    end
  end
end
