defmodule Troupe.Plane.Repo.Migrations.TriggerKeys do
  @moduledoc """
  A key of the trigger's own, so an executor outside the plane can fire it.

  Until now the only way to fire a trigger was a credential that could do everything
  else too: a person's token, or a principal's secret, which administers every trigger
  in its team and creates sessions besides. Handing that to a CI job to call one webhook
  is handing it the team.

  Hashed and salted exactly as a principal's secret is, and never readable again — the
  one time it is legible is the response to the rotation that minted it. `key_rotated_at`
  and `key_rotated_by` are the audit an administrator needs when they are asked whether
  the key that fired something last month is the key that exists today.
  """

  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add(:key_hash, :string)
      add(:key_salt, :string)
      add(:key_rotated_at, :utc_datetime_usec)
      add(:key_rotated_by, :string)
    end
  end
end
