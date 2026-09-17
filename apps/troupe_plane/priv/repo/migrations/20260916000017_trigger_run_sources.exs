defmodule Troupe.Plane.Repo.Migrations.TriggerRunSources do
  @moduledoc """
  How a firing arrived, and a digest of what arrived with it.

  A cron minute, an executor's webhook, a CI job, an API call and a person's "run now"
  produced runs that were distinguishable only by `fired_by` — a free string nobody
  validated, which said `scheduler` for one source and a subject for the other four.
  `source` is the discriminator, from a closed set, and it is what the durable
  `trigger_fired` event carries.

  `payload_digest` is a hash of the event as it arrived. The run already keeps the event
  itself, capped; the digest is over the whole of it, so two firings can be compared for
  sameness without the plane having to have kept the larger one.
  """

  use Ecto.Migration

  def up do
    alter table(:trigger_runs) do
      add(:source, :string)
      add(:payload_digest, :string)
    end

    # What the old rows were. The scheduler is the only thing that ever wrote
    # `scheduler`, so that one is certain; everything else reached `fire/4` through the
    # plane API, which is `api`. Guessing `webhook` for the rest would put a source on
    # rows that never had one.
    execute("UPDATE trigger_runs SET source = 'schedule' WHERE fired_by = 'scheduler'")
    execute("UPDATE trigger_runs SET source = 'api' WHERE source IS NULL")

    alter table(:trigger_runs) do
      modify(:source, :string, null: false)
    end

    create(index(:trigger_runs, [:source, :fired_at]))
  end

  def down do
    drop(index(:trigger_runs, [:source, :fired_at]))

    alter table(:trigger_runs) do
      remove(:payload_digest)
      remove(:source)
    end
  end
end
