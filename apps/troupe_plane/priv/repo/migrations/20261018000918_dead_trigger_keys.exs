defmodule Troupe.Plane.Repo.Migrations.DeadTriggerKeys do
  @moduledoc """
  The keys kept on triggers that no longer have one. Only a webhook that names no
  repository has a key (`Troupe.Plane.Triggers.keyed?/1`), and a trigger that stopped
  being one kept its key, dead: `POST /trigger/<id>` opened nothing with it, but a listing
  still said `has_key`. The plane drops a key when a trigger stops taking one; this drops
  those kept before it did. Nothing is put back: a dropped key opened nothing.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE triggers
       SET key_hash = NULL, key_salt = NULL, key_rotated_at = NULL, key_rotated_by = NULL
     WHERE key_hash IS NOT NULL
       AND NOT (source->>'kind' = 'webhook'
                AND (source->'repository' IS NULL OR source->'repository' = 'null'::jsonb))
    """)
  end

  def down, do: :ok
end
