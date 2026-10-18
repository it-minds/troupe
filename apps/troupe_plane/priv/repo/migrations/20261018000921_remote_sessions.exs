defmodule Troupe.Plane.Repo.Migrations.RemoteSessions do
  @moduledoc """
  The laptop sessions their people offer to the plane for steering from another device
  (#58): who offered each, from which device, to whom, and since when it is offline. A row
  is metadata and nothing of what the session says; the workspace is its last name.
  """

  use Ecto.Migration

  def change do
    create table(:remote_sessions, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :owner_subject, :string, null: false
      add :device, :string, null: false
      add :workspace, :string
      add :shares, :map, null: false, default: %{}
      add :offered_at, :utc_datetime_usec, null: false
      add :offline_since, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:remote_sessions, [:owner_subject, :device])
  end
end
