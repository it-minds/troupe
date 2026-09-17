defmodule Troupe.Plane.Repo.Migrations.TriggerRevisions do
  @moduledoc """
  A run names an immutable, content-addressed revision instead of a row somebody edited.

  `trigger_runs` pointed at the mutable `triggers` row, so editing a prompt template
  rewrote the provenance of every run that had used the old one. The rendered prompt
  survives in the session's own log, so the content was never lost — but which document
  produced it, under which terms and as which principal, was.

  A revision is a property of the *trigger document*, not of any one source: the same
  hash covers a schedule, a webhook and every other way a trigger is fired, because what
  it covers is what the run would be, not what caused it. `enabled` is deliberately not
  part of it — switching a trigger off does not change what a run would be, and a
  revision per toggle would be history made of noise.

  The backfill creates revision 1 for every existing trigger from its current row and
  points every existing run at it. That is honest rather than complete: revision 1 is
  what can be proven, and `reconstructed` says so on the row rather than in a comment.
  """

  use Ecto.Migration

  alias Troupe.Protocol.Canonical

  def up do
    create table(:trigger_revisions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:trigger_id, references(:triggers, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # Monotonic per trigger, so a person can say "revision 3" out loud. The hash is
      # what two systems join on; the number is what a person reads.
      add(:revision, :integer, null: false)
      add(:hash, :string, null: false)

      add(:profile, :string, null: false)
      add(:agent, :string)

      add(
        :principal_id,
        references(:service_principals, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:prompt_template, :text, null: false, default: "")
      add(:terms, :map, null: false, default: %{})
      add(:visibility, :string, null: false, default: "team")
      add(:review, :string, null: false, default: "required")
      add(:notify, {:array, :string}, null: false, default: [])
      add(:concurrency, :integer, null: false, default: 1)
      add(:source, :map, null: false, default: %{})

      # True where the row was made by this migration from the trigger as it stood,
      # rather than from a `trigger.put` somebody made.
      add(:reconstructed, :boolean, null: false, default: false)
      add(:created_by, :string)

      # No `updated_at`: a revision is immutable, and a column that cannot change is a
      # column that should not exist.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:trigger_revisions, [:trigger_id, :revision]))
    create(unique_index(:trigger_revisions, [:trigger_id, :hash]))

    alter table(:trigger_runs) do
      add(
        :revision_id,
        references(:trigger_revisions, type: :binary_id, on_delete: :restrict)
      )
    end

    create(index(:trigger_runs, [:revision_id]))

    flush()

    backfill()

    # Not null only after the backfill, so a deployment with existing runs is one
    # migration rather than a migration and a chore somebody remembers.
    alter table(:trigger_runs) do
      modify(:revision_id, :binary_id, null: false)
    end
  end

  def down do
    alter table(:trigger_runs) do
      remove(:revision_id)
    end

    drop(table(:trigger_revisions))
  end

  @document ~w(profile agent principal_id prompt_template terms visibility review notify
               concurrency source)

  defp backfill do
    # `id` and `principal_id` are selected twice on purpose. Postgrex hands a `uuid`
    # back as sixteen raw bytes, which is what the inserts below want and is not a
    # string any JSON encoder will take — and the hash has to be computed over the same
    # representation `Revision.document/1` uses at runtime, where Ecto has already made
    # it the text form. A hash over the bytes would make every trigger revise itself on
    # the first `trigger.put` after this migration, for no change.
    %{rows: rows, columns: columns} =
      repo().query!("""
      SELECT id, id::text AS id_text, profile, agent,
             principal_id, principal_id::text AS principal_id_text,
             prompt_template, terms, visibility, review, notify, concurrency, source,
             created_by
      FROM triggers
      """)

    for row <- rows do
      trigger = columns |> Enum.zip(row) |> Map.new()
      id = trigger["id"]

      document =
        @document
        |> Map.new(fn key -> {key, trigger[key]} end)
        |> Map.put("principal_id", trigger["principal_id_text"])

      hash = Canonical.hash(document)

      %{rows: [[revision_id]]} =
        repo().query!(
          """
          INSERT INTO trigger_revisions
            (id, trigger_id, revision, hash, profile, agent, principal_id, prompt_template,
             terms, visibility, review, notify, concurrency, source, reconstructed,
             created_by, inserted_at)
          VALUES (gen_random_uuid(), $1, 1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
                  true, $13, now())
          RETURNING id
          """,
          [
            id,
            hash,
            trigger["profile"],
            trigger["agent"],
            trigger["principal_id"],
            trigger["prompt_template"],
            trigger["terms"],
            trigger["visibility"],
            trigger["review"],
            trigger["notify"],
            trigger["concurrency"],
            trigger["source"],
            trigger["created_by"]
          ]
        )

      repo().query!(
        "UPDATE trigger_runs SET revision_id = $1 WHERE trigger_id = $2",
        [revision_id, id]
      )
    end
  end
end
