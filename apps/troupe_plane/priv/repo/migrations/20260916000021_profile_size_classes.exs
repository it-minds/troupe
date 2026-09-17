defmodule Troupe.Plane.Repo.Migrations.ProfileSizeClasses do
  @moduledoc """
  Three questions in place of seven numbers.

  `size_class` — how demanding a session is here. `max_sessions` — how far this may grow,
  in sessions at once rather than workers, because that is the number an administrator can
  reason about and the number a refusal can quote. `warm_workers` — whether to keep one
  up when nothing is running.

  `replicas` stays on the row and stops being an administrator's field: from here the
  plane writes it, the way it already writes `spec.teams`.

  The class is backfilled from what each profile was *already doing* rather than
  defaulted. A profile packing several sessions onto a worker was standard whatever its
  resources said; one running them nearly alone was heavy. An administrator who set this
  up by hand should not find their careful `sessionsPerPod: 1` turned into four by a
  migration.

  `max_sessions` is deliberately left null everywhere: no ceiling, bounded by the team's
  money. A ceiling is a decision a person makes, and a migration that invented one for
  every profile would be a migration that started refusing sessions on Monday.
  """

  use Ecto.Migration

  def up do
    alter table(:profiles) do
      add(:size_class, :string)
      add(:max_sessions, :integer)
      add(:warm_workers, :integer, null: false, default: 0)
      # When this profile last had an active session, so scale-to-zero can wait a grace
      # period rather than removing a worker the moment the last session goes dormant.
      add(:idle_since, :utc_datetime_usec)
    end

    # A session that exists and has no worker yet. The prompt rides with it, because a
    # session nobody is attached to has to do its first turn alone and a wait that
    # dropped the prompt would produce a session that started and then sat there. It is
    # the only piece of session content the plane holds, it is held for seconds, and it
    # is cleared the moment the session is placed.
    alter table(:sessions) do
      add(:pending_prompt, :text)
    end

    execute("UPDATE profiles SET size_class = 'heavy' WHERE sessions_per_pod <= 2")
    execute("UPDATE profiles SET size_class = 'standard' WHERE size_class IS NULL")

    alter table(:profiles) do
      modify(:size_class, :string, null: false)
    end
  end

  def down do
    alter table(:sessions) do
      remove(:pending_prompt)
    end

    alter table(:profiles) do
      remove(:idle_since)
      remove(:warm_workers)
      remove(:max_sessions)
      remove(:size_class)
    end
  end
end
