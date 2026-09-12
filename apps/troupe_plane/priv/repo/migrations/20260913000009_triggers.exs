defmodule Troupe.Plane.Repo.Migrations.Triggers do
  @moduledoc """
  Sessions nobody starts by hand: the definitions, and the record of each firing.

  `triggers` is the source of truth an admin edits and audits — what fires, as whom, on
  which profile, with which prompt template and terms. `trigger_runs` is the record a
  person reads afterwards: the event that fired, the session it produced, and who
  reviewed it. Neither is content. A run's `event` is what the provider filter let
  through (an issue key, a title, a URL), never a whole payload, and is capped at 16 KiB
  by the context so a webhook body cannot become a place to hide instructions.

  Neither table can be rebuilt from object storage, which is new for this database: it
  still costs no sessions to lose, but it costs the trigger definitions, which is why
  the CLI takes them from files that live in git.
  """

  use Ecto.Migration

  def change do
    create table(:triggers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)

      add(
        :principal_id,
        references(:service_principals, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:profile, :string, null: false)
      add(:agent, :string)
      add(:enabled, :boolean, null: false, default: true)
      add(:source, :map, null: false, default: %{})
      add(:prompt_template, :text, null: false, default: "")
      add(:terms, :map, null: false, default: %{})
      add(:visibility, :string, null: false, default: "team")
      add(:review, :string, null: false, default: "required")
      add(:notify, {:array, :string}, null: false, default: [])
      add(:concurrency, :integer, null: false, default: 1)
      # When the in-plane scheduler last fired this one, so a tick can ask "has a cron
      # minute passed since" rather than keeping that in a process.
      add(:last_fired_at, :utc_datetime_usec)
      add(:created_by, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:triggers, [:team_id, :name]))
    create(index(:triggers, [:enabled]))

    create table(:trigger_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:trigger_id, references(:triggers, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # The executor's key. A retry with the same key gets the same run and never a
      # second session, which is what lets Hatchet retry a failed create blindly.
      add(:idempotency_key, :string, null: false)
      add(:session_id, references(:sessions, type: :string, on_delete: :nilify_all))
      add(:fired_at, :utc_datetime_usec, null: false)
      add(:fired_by, :string)
      add(:event, :map, null: false, default: %{})
      add(:state, :string, null: false, default: "created")
      add(:reviewed_by, :string)
      add(:reviewed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:trigger_runs, [:idempotency_key]))
    create(index(:trigger_runs, [:trigger_id, :fired_at]))
    create(index(:trigger_runs, [:session_id]))
  end
end
