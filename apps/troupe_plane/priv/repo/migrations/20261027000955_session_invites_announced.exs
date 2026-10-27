defmodule Troupe.Plane.Repo.Migrations.SessionInvitesAnnounced do
  @moduledoc """
  When a pod session's log was given an invitation's line (#765).

  `session_invites.announced_at` is set once the pod holding the session wrote
  `session_invited`; an invitation into a session no pod holds has none, and its line is
  written at the session's next activation. The rows already here are taken as said: the
  line was asked for when they were made, and saying it again would write it twice.
  """

  use Ecto.Migration

  def up do
    alter table(:session_invites) do
      add :announced_at, :utc_datetime_usec
    end

    execute("UPDATE session_invites SET announced_at = invited_at")
  end

  def down do
    alter table(:session_invites) do
      remove :announced_at
    end
  end
end
