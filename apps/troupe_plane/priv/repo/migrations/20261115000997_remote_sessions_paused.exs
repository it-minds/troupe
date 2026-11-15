defmodule Troupe.Plane.Repo.Migrations.RemoteSessionsPaused do
  @moduledoc """
  An offered laptop session whose laptop is away says why: `stopped`, its daemon said it
  was stopping, or `offline`, its connection went without a word or stopped answering.
  `remote.list` says it as `paused`, and offering again clears it.

  `paused_reason` is `NULL` for a row from before, and for every offer whose laptop is
  there.
  """

  use Ecto.Migration

  def change do
    alter table(:remote_sessions) do
      add(:paused_reason, :string)
    end
  end
end
