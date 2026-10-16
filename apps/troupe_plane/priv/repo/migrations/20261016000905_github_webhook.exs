defmodule Troupe.Plane.Repo.Migrations.GithubWebhook do
  @moduledoc """
  GitHub as the trigger (#147 slice 3).

  `github_deliveries` is every delivery the App's webhook took, by GitHub's own id
  (`X-GitHub-Delivery`), so a delivery GitHub sends again — a redelivery, a retry after a
  timeout — is answered and does nothing twice. It keeps the event, the action, when it
  came and what the plane did with it: the runs it fired, the session it resumed, or why
  it did neither. Never the body: an issue's text is on GitHub, and a run keeps the part
  of it a session was given.

  `github_app.webhook_secret_version` is the version OpenBao's transit engine holds the
  webhook secret at, which is all the plane knows of the secret.
  """

  use Ecto.Migration

  def change do
    create table(:github_deliveries, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:event, :string, null: false)
      add(:action, :string)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:outcome, :map)
    end

    create(index(:github_deliveries, [:received_at]))

    alter table(:github_app) do
      add(:webhook_secret_version, :integer)
    end
  end
end
