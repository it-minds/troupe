defmodule Troupe.Plane.Repo.Migrations.SessionAgent do
  @moduledoc """
  A session's row says which agent it runs as: the one `session.create` named, then the one
  its pod reports it was switched to. A client offering "start like last time" reads it
  from a listing rather than replaying a log, and a session that waited for a place starts
  as the agent it was asked for rather than the profile's default.

  `sessions.agent` is `NULL` for a row from before, and for a session created without
  naming one, which runs as its profile's default.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:agent, :string)
    end
  end
end
