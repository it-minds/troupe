defmodule Troupe.Plane.Fleet.Worker do
  @moduledoc """
  One pod, as the plane sees it.

  A pod enrols by presenting its projected ServiceAccount token; the namespace in the
  answer decides the profile, so a pod can only enrol as its own. After that it
  heartbeats capacity, active sessions, disk use and its loaded bundle hash, and the
  plane stops placing on it the moment it goes quiet.

  `namespace` and `pod_name` together are the identity: a pod that comes back after a
  restart is the same pod, with the same ordinal and the same PVC.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workers" do
    field :profile, :string
    field :ordinal, :integer
    field :pod_name, :string
    field :namespace, :string
    field :endpoint, :string
    field :node_name, :string

    field :enrolled_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :healthy, :boolean, default: false
    field :draining, :boolean, default: false
    field :capacity, :integer, default: 0
    field :active_sessions, :integer, default: 0
    field :disk_used_bytes, :integer, default: 0
    field :disk_total_bytes, :integer, default: 0
    field :bundle_hash, :string
    field :version, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :profile,
    :ordinal,
    :pod_name,
    :namespace,
    :endpoint,
    :node_name,
    :enrolled_at,
    :last_heartbeat_at,
    :healthy,
    :draining,
    :capacity,
    :active_sessions,
    :disk_used_bytes,
    :disk_total_bytes,
    :bundle_hash,
    :version
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(worker, attrs) do
    worker
    |> cast(attrs, @fields)
    |> validate_required([:profile, :ordinal, :pod_name, :namespace])
    |> unique_constraint([:namespace, :pod_name])
  end

  @doc """
  How full a pod's disk is, as a fraction.

  Placement skips a pod above the high watermark, because a session that cannot write
  its workspace is worse than one that waited for room.
  """
  @spec disk_fraction(t()) :: float()
  def disk_fraction(%__MODULE__{disk_total_bytes: total}) when total <= 0, do: 0.0
  def disk_fraction(%__MODULE__{disk_used_bytes: used, disk_total_bytes: total}), do: used / total
end
