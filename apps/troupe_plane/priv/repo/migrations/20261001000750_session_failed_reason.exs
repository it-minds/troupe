defmodule Troupe.Plane.Repo.Migrations.SessionFailedReason do
  @moduledoc """
  Why the harness stopped a session's last turn, beside why it finished.

  A turn the failure guard stopped (`tool_failures`) or a root that kept crashing ended
  (`agent_failed`) leaves the root at rest, `idle`, and the row read like a turn that had
  done its work: a trigger's run was never failed and its target was never told. The
  worker reports `turn_ended`'s reason with the other lifecycle facts until another turn
  starts, and it is rebuildable from the log the same way (Decision 750).
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:failed_reason, :string)
    end
  end
end
