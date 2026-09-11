defmodule Troupe.Plane.Repo.Migrations.Fleet do
  @moduledoc """
  What is running, and what it is configured with.

  `profiles` mirrors the `WorkerProfile` resources the plane wrote, so placement can
  answer "how many sessions fit" without asking Kubernetes on every create. It is a
  cache of desired state, not a second source of truth: the operator reads the custom
  resource, never this.

  `workers` is presence. A pod enrols, heartbeats, and is marked unhealthy when it
  stops — and while it is unhealthy nothing is placed on it.
  """

  use Ecto.Migration

  def change do
    create table(:profiles, primary_key: false) do
      add :name, :string, primary_key: true
      add :replicas, :integer, null: false, default: 1
      add :sessions_per_pod, :integer, null: false, default: 4
      add :config_bundle_channel, :string, null: false, default: "stable"
      add :image, :string
      add :workers_domain, :string
      add :spec, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create table(:workers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :profile, :string, null: false
      add :ordinal, :integer, null: false
      add :pod_name, :string, null: false
      add :namespace, :string, null: false
      add :endpoint, :string
      add :node_name, :string

      # Presence and capacity, from heartbeats.
      add :enrolled_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :healthy, :boolean, null: false, default: false
      add :draining, :boolean, null: false, default: false
      add :capacity, :integer, null: false, default: 0
      add :active_sessions, :integer, null: false, default: 0
      add :disk_used_bytes, :bigint, null: false, default: 0
      add :disk_total_bytes, :bigint, null: false, default: 0
      add :bundle_hash, :string
      add :version, :string

      timestamps(type: :utc_datetime_usec)
    end

    # A pod is its namespace and name. Enrolling twice is the same pod coming back.
    create unique_index(:workers, [:namespace, :pod_name])
    create index(:workers, [:profile, :healthy, :draining])

    create table(:config_bundles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel, :string, null: false
      add :version, :integer, null: false
      # Workers verify what they fetched against this before applying it.
      add :hash, :string, null: false
      add :content, :map, null: false, default: %{}
      add :published_at, :utc_datetime_usec
      add :published_by, :string
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:config_bundles, [:channel, :version])
    create index(:config_bundles, [:hash])
  end
end
