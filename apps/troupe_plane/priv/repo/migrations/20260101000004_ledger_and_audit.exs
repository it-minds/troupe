defmodule Troupe.Plane.Repo.Migrations.LedgerAndAudit do
  @moduledoc """
  What it cost, and who did what.

  The usage ledger is append-only and unique on the gateway's request id, which is the
  one identifier both Troupe and the LLM gateway agree on. That uniqueness is what
  makes the nightly reconciliation meaningful: a request the gateway billed and the
  ledger does not have is drift, and a request counted twice is impossible rather than
  merely unlikely.
  """

  use Ecto.Migration

  def change do
    create table(:usage_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :team_id, references(:teams, type: :binary_id, on_delete: :nilify_all)
      add :owner_subject, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_micros, :bigint, null: false, default: 0
      # The gateway's own identifier for the request. Both sides know it, so it is what
      # reconciliation joins on.
      add :gateway_request_id, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:usage_records, [:gateway_request_id])
    create index(:usage_records, [:team_id, :occurred_at])
    create index(:usage_records, [:session_id])

    # Reservations against a team's budget, held while a session runs. `TeamBudget`
    # serialises these, so a reservation is never granted twice for the same room.
    create table(:budget_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      add :session_id, :string, null: false
      add :amount_micros, :bigint, null: false
      add :released_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:budget_reservations, [:session_id])
    create index(:budget_reservations, [:team_id, :released_at])

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor, :string, null: false
      add :action, :string, null: false
      add :subject_kind, :string, null: false
      add :subject_id, :string
      add :detail, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:audit_events, [:occurred_at])
    create index(:audit_events, [:subject_kind, :subject_id])
    create index(:audit_events, [:actor])
  end
end
