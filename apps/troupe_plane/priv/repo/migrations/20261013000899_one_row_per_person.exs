defmodule Troupe.Plane.Repo.Migrations.OneRowPerPerson do
  @moduledoc """
  One row per person, and somewhere to keep what outlives a removed one.

  `users.external_id` is what SCIM says the person is called at the provider. Two rows
  carried the same one where a plane switched `subject_claim` after SCIM had pushed: the
  next sign-in moved the person to the new claim's value and left their `external_id`, and
  the next push, finding nobody under that value, made a second row with it. So did a
  sign-in under a claim that matched SCIM's `externalId` while SCIM's row had been moved
  away from it.

  Those rows are merged here, before the index that says it cannot happen again, so the
  migration succeeds on a plane that has them. What counts as one person is a row whose
  `external_id` is the value and every row whose `subject` is: SCIM's row, the one whose
  `subject` is also the value, or else the newest that carries it, is kept, because its
  `id` is what the provider holds; the others are folded into it as a re-key folds a
  moved person into SCIM's row at sign-in. Rows that only look alike, the same email
  or display name under different keys, are not merged: nothing proves they are one
  person, and `Troupe.Plane.Identity.lookalikes/0` reports them for an administrator.

  In the migration rather than an admin task, because the index has to come after the
  merge and before the plane runs: a task somebody runs after the upgrade would leave the
  index unbuildable on exactly the planes that need it.

  `person_tombstones` is what a SCIM `DELETE` leaves of somebody whose row it removed.
  """

  use Ecto.Migration

  alias Troupe.Protocol.Canonical

  require Logger

  # The same lock `Troupe.Plane.Audit` serialises the trail on.
  @chain_lock 8_374_221

  def up do
    create table(:person_tombstones, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      # The row's id, which a provider that removed them addressed them by.
      add(:former_id, :binary_id, null: false)
      add(:subject, :string, null: false)
      add(:external_id, :string)
      add(:user_name, :string)
      add(:display_name, :string)
      # Their name at the key manager, under which what they stored still is, until an
      # erasure removes it.
      add(:kms_name, :string, null: false)
      add(:removed_by, :string, null: false)
      add(:removed_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:person_tombstones, [:subject]))
    create(unique_index(:person_tombstones, [:kms_name]))

    flush()

    merge(repo())

    drop(index(:users, [:external_id]))
    create(unique_index(:users, [:external_id], where: "external_id IS NOT NULL"))
  end

  def down do
    drop(index(:users, [:external_id]))
    create(index(:users, [:external_id]))
    drop(table(:person_tombstones))
  end

  @doc """
  Fold every set of rows that is one person into one row, and say what was folded.

  Public so a test can run it on a database seeded with duplicates; the migration is its
  one caller in production. One set at a time until none is left, since a row moved in one
  merge can be the one another merge keeps.
  """
  @spec merge(module()) :: [map()]
  def merge(repo), do: merge(repo, [])

  defp merge(repo, done) do
    case next_set(repo) do
      nil ->
        Enum.reverse(done)

      value ->
        merged = merge_set(repo, value)
        Logger.info("troupe plane: merged #{inspect(merged)}")
        merge(repo, [merged | done])
    end
  end

  # The rows that are the person SCIM calls `$1`: those carrying it as their `external_id`,
  # and those keyed on it that SCIM has not named otherwise. A row keyed on it under
  # another `external_id` is somebody SCIM knows by that other value, and is left alone.
  @one_person "u.external_id = $1 OR (u.subject = $1 AND (u.external_id IS NULL OR u.external_id = $1))"

  # A value more than one row answers to, where at least one carries it as its
  # `external_id`.
  defp next_set(repo) do
    %{rows: rows} =
      repo.query!("""
      SELECT v.value
        FROM (SELECT DISTINCT external_id AS value FROM users WHERE external_id IS NOT NULL) AS v
       WHERE (SELECT count(*) FROM users u
               WHERE #{String.replace(@one_person, "$1", "v.value")}) > 1
       ORDER BY v.value
       LIMIT 1
      """)

    case rows do
      [[value]] -> value
      [] -> nil
    end
  end

  defp merge_set(repo, value) do
    %{rows: rows, columns: columns} =
      repo.query!(
        """
        SELECT id, id::text AS id_text, subject, external_id, kms_name, budget_micros,
               inserted_at
          FROM users u
         WHERE #{@one_person}
         ORDER BY inserted_at, id
           FOR UPDATE
        """,
        [value]
      )

    people = Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
    kept = keep(people, value)
    folded = Enum.reject(people, &(&1["id"] == kept["id"]))

    # What they stored at the key manager is under the name of the row known first, from
    # before there were two; the other names are reported, since nothing is moved there.
    oldest = hd(people)
    name = oldest["kms_name"] || oldest["subject"]

    for row <- folded, do: fold(repo, row, kept)

    budget = kept["budget_micros"] || Enum.find_value(folded, & &1["budget_micros"])

    repo.query!("UPDATE users SET kms_name = $1, budget_micros = $2 WHERE id = $3", [
      name,
      budget,
      kept["id"]
    ])

    dropped =
      people
      |> Enum.map(&(&1["kms_name"] || &1["subject"]))
      |> Enum.reject(&(&1 == name))

    detail = %{
      "external_id" => value,
      "kept" => kept["id_text"],
      "subject" => kept["subject"],
      "folded" => Enum.map(folded, &%{"id" => &1["id_text"], "subject" => &1["subject"]}),
      "kms_names_left" => dropped
    }

    audit(repo, kept["subject"], detail)
    detail
  end

  # SCIM's row: the one a push keys on, whose subject is the value, else the newest that
  # carries the value, which is the one the provider created last and holds the id of.
  defp keep(people, value) do
    scim = Enum.filter(people, &(&1["external_id"] == value))
    Enum.find(scim, &(&1["subject"] == value)) || List.last(scim)
  end

  # What `Troupe.Plane.Identity.rekey/2` moves when it folds a person into SCIM's row, in
  # SQL, because this is the plane as it stood at this migration and not as the module is
  # later. The audit trail and every `*_by` keep the name they were written with.
  defp fold(repo, row, kept) do
    old = row["subject"]
    new = kept["subject"]

    repo.query!("UPDATE sessions SET owner_id = $1 WHERE owner_id = $2", [kept["id"], row["id"]])

    for {table, column} <- [
          {"sessions", "owner_subject"},
          {"session_shares", "audience"},
          {"usage_records", "owner_subject"},
          {"budget_reservations", "owner_subject"},
          {"service_principals", "sponsor_subject"}
        ],
        old != new do
      repo.query!("UPDATE #{table} SET #{column} = $1 WHERE #{column} = $2", [new, old])
    end

    for {table, scope} <- [{"session_acls", "session_id"}, {"team_admins", "team_id"}],
        old != new do
      repo.query!(
        """
        DELETE FROM #{table}
         WHERE subject = $1
           AND #{scope} IN (SELECT #{scope} FROM #{table} WHERE subject = $2)
        """,
        [old, new]
      )

      repo.query!("UPDATE #{table} SET subject = $1 WHERE subject = $2", [new, old])
    end

    if old != new do
      repo.query!(
        """
        UPDATE sessions
           SET origin = jsonb_set(origin, '{principal,subject}', to_jsonb($1::text))
         WHERE origin->'principal'->>'subject' = $2
        """,
        [new, old]
      )

      repo.query!(
        "UPDATE triggers SET notify = array_replace(notify, $1, $2) WHERE $1 = ANY(notify)",
        [old, new]
      )
    end

    repo.query!("DELETE FROM users WHERE id = $1", [row["id"]])
  end

  # One `person.merge` row on the audit trail per set, chained as `Troupe.Plane.Audit`
  # chains every row: over its own content, pointing back at the row before it.
  defp audit(repo, subject, detail) do
    repo.query!("SELECT pg_advisory_xact_lock($1)", [@chain_lock])

    %{rows: head} =
      repo.query!("""
      SELECT hash FROM audit_events WHERE hash IS NOT NULL
       ORDER BY occurred_at DESC, id DESC LIMIT 1
      """)

    actor = "migration:one_row_per_person"
    at = DateTime.utc_now()

    hash =
      Canonical.hash(%{
        "actor" => actor,
        "on_behalf_of" => actor,
        "action" => "person.merge",
        "subject_kind" => "person",
        "subject_id" => subject,
        "detail" => detail,
        "occurred_at" => DateTime.to_iso8601(at)
      })

    repo.query!(
      """
      INSERT INTO audit_events
        (id, actor, on_behalf_of, action, subject_kind, subject_id, detail, occurred_at,
         hash, prev_hash, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $1, 'person.merge', 'person', $2, $3, $4, $5, $6, $4, $4)
      """,
      [actor, subject, detail, at, hash, head |> List.first() |> then(&(&1 && hd(&1)))]
    )
  end
end
