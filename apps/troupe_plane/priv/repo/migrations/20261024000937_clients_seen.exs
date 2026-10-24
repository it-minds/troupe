defmodule Troupe.Plane.Repo.Migrations.ClientsSeen do
  @moduledoc """
  Which version each person's clients last ran (#657).

  One row per person and component (`tui`, `daemon`, `desktop`), written at `initialize`
  and moved on by the next one: the version the client gave, the platform where it named
  one, when that version was first seen and when the client was last seen. Never a
  history. A client the plane refused is not written, and a person's rows go with them.
  """

  use Ecto.Migration

  def change do
    create table(:clients_seen, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :component, :string, primary_key: true
      add :version, :string, null: false
      add :platform, :string
      add :since, :utc_datetime_usec, null: false
      add :seen_at, :utc_datetime_usec, null: false
    end

    create index(:clients_seen, [:component])
  end
end
