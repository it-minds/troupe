defmodule Troupe.Plane.Repo.Migrations.MemoryReads do
  @moduledoc """
  Which memory each running session read at its last turn (#55).

  One row per session, moved on by its next turn: on a pod, as the turn begins
  (`session.memory.read`); on a person's machine, with the daemon's poll of `me.memory`.
  `documents` is each document's scope, name, version and hash, never its text. Never a
  history: "who is behind" is a question about now. A person's rows go with them.
  """

  use Ecto.Migration

  def change do
    create table(:memory_reads, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :owner_subject, :string
      # `pod` or `machine`: where the session runs, which is how a nudge reaches it.
      add :where, :string, null: false
      add :documents, {:array, :map}, null: false, default: []
      add :turn_at, :utc_datetime_usec
      add :seen_at, :utc_datetime_usec, null: false
    end

    create index(:memory_reads, [:owner_id])
    create index(:memory_reads, [:seen_at])
  end
end
