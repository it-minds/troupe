defmodule Troupe.Plane.Repo.Migrations.GithubApp do
  @moduledoc """
  The plane's GitHub App (#147 slice 1), and the repository a session names.

  One row, keyed `app`, because a plane has one App: its id, the API it lives at, the
  installations an organisation has linked, and what is known about the private key —
  its type, its fingerprint and the version OpenBao holds it at. Never the key itself,
  which is imported into OpenBao's transit engine and cannot be read back by anybody,
  the plane included.

  `sessions.repository` is the repository a session clones on its first activation:
  `{owner, name, ref}`, checked against the App's installations when the session is
  created. Null for every session before this, and for every session that names none.
  """

  use Ecto.Migration

  def change do
    create table(:github_app, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:app_id, :bigint)
      add(:api_url, :string)
      add(:installations, {:array, :map}, null: false, default: [])
      add(:key_type, :string)
      add(:key_fingerprint, :string)
      add(:key_version, :integer)
      add(:updated_by, :string)

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:sessions) do
      add(:repository, :map)
    end
  end
end
