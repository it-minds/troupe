defmodule Troupe.Plane.Repo.Migrations.SessionSensitive do
  @moduledoc """
  A sensitive session (#1239): since when, and by what (the tool whose call marked it) or
  whom (the person who marked it by hand, as `person:<subject>`). Null for a session that
  is not sensitive, which is every row from before the columns. Written once, by the pod's
  `session.status` or by `session.sensitive.set`, and never cleared: nothing unmarks a
  session.

  A share of a sensitive session that its profile's `sensitive.sharing: ask` holds for a
  team administrator waits in `session_share_requests`: the session, what was asked
  (`visibility`, `invite`, `grant` or `artifact`, with its parameters), who asked, and once
  answered, who answered and how. No table there fits it: a review is of a run's outcome and
  a memory proposal of an entry, neither of a share waiting to be applied.

  Additive only, so a plane from before it ignores the columns and the table, and a
  rollback keeps working.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:sensitive_at, :utc_datetime_usec)
      add(:sensitive_by, :string)
    end

    create table(:session_share_requests, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false)
      add(:team, :string)
      add(:kind, :string, null: false)
      add(:params, :map, null: false, default: %{})
      add(:requested_by, :string, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:decided_by, :string)
      add(:decided_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:session_share_requests, :session_share_requests_kind,
        check: "kind IN ('visibility', 'invite', 'grant', 'artifact')"
      )
    )

    create(
      constraint(:session_share_requests, :session_share_requests_state,
        check: "state IN ('pending', 'approved', 'declined')"
      )
    )

    # What a team administrator's queue asks: the pending requests, oldest first.
    create(
      index(:session_share_requests, [:team, :inserted_at],
        where: "state = 'pending'",
        name: :session_share_requests_pending
      )
    )
  end
end
