defmodule Troupe.Plane.Fleet do
  @moduledoc """
  What is running, and how much room it has.

  Presence is a heartbeat and nothing else. A pod that has stopped heartbeating past
  the lease timeout is unhealthy, and an unhealthy pod is not placed on — the plane does
  not wait to be told, because the interesting failure is a pod that cannot tell anyone
  anything.
  """

  import Ecto.Query

  alias Troupe.Plane.Fleet.{Profile, Worker}
  alias Troupe.Plane.Repo

  # Past this with no heartbeat a pod is presumed lost. Fifteen seconds is the done
  # item's number, and heartbeats are every five.
  @lease_timeout_ms 15_000

  @doc "How long a pod may go quiet before it is presumed lost."
  @spec lease_timeout_ms() :: pos_integer()
  def lease_timeout_ms, do: Application.get_env(:troupe_plane, :lease_timeout_ms, @lease_timeout_ms)

  # -- profiles ---------------------------------------------------------------

  @doc "Record what a profile is, so placement need not ask Kubernetes."
  @spec put_profile(map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def put_profile(attrs) do
    name = attrs[:name] || attrs["name"]

    (Repo.get(Profile, name) || %Profile{})
    |> Profile.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "One profile, or `nil`."
  @spec get_profile(String.t()) :: Profile.t() | nil
  def get_profile(name), do: Repo.get(Profile, name)

  @doc "Every profile."
  @spec list_profiles() :: [Profile.t()]
  def list_profiles, do: Repo.all(from p in Profile, order_by: p.name)

  @doc "The profiles following a config bundle channel."
  @spec profiles_on_channel(String.t()) :: [String.t()]
  def profiles_on_channel(channel) do
    Repo.all(from p in Profile, where: p.config_bundle_channel == ^channel, select: p.name, order_by: p.name)
  end

  # -- workers ----------------------------------------------------------------

  @doc """
  Record that a pod has enrolled.

  Idempotent by namespace and pod name: a pod that restarts is the same pod, with the
  same ordinal and the same disk. Enrolling resets its session count, because whatever
  it was running did not survive the restart.
  """
  @spec enrol(map()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def enrol(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.put(:enrolled_at, now)
      |> Map.put(:last_heartbeat_at, now)
      |> Map.put(:healthy, true)
      |> Map.put_new(:active_sessions, 0)

    existing = Repo.get_by(Worker, namespace: attrs.namespace, pod_name: attrs.pod_name)

    (existing || %Worker{})
    |> Worker.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Record a heartbeat: capacity, load, disk, and the bundle the pod has loaded."
  @spec heartbeat(Worker.t() | Ecto.UUID.t(), map()) :: {:ok, Worker.t()} | {:error, term()}
  def heartbeat(%Worker{} = worker, attrs) do
    worker
    |> Worker.changeset(Map.merge(attrs, %{last_heartbeat_at: DateTime.utc_now(), healthy: true}))
    |> Repo.update()
  end

  def heartbeat(id, attrs) do
    case Repo.get(Worker, id) do
      nil -> {:error, :not_found}
      worker -> heartbeat(worker, attrs)
    end
  end

  @doc "One pod, or `nil`."
  @spec get_worker(Ecto.UUID.t()) :: Worker.t() | nil
  def get_worker(id), do: Repo.get(Worker, id)

  @doc "Every pod of a profile, whatever its state."
  @spec list_workers(String.t()) :: [Worker.t()]
  def list_workers(profile) do
    Repo.all(from w in Worker, where: w.profile == ^profile, order_by: w.ordinal)
  end

  @doc """
  Pods a session could be placed on: healthy, not draining, below the disk high
  watermark, and with room.

  Ordered by how loaded they are, so the least-loaded comes first. The order is part of
  the answer, not a convenience: spreading sessions is what keeps one pod's loss from
  taking most of the work with it.
  """
  @spec placeable(String.t(), keyword()) :: [Worker.t()]
  def placeable(profile, opts \\ []) do
    high_watermark = Keyword.get(opts, :high_watermark, high_watermark())
    cutoff = DateTime.add(DateTime.utc_now(), -lease_timeout_ms(), :millisecond)

    Repo.all(
      from w in Worker,
        where:
          w.profile == ^profile and w.healthy and not w.draining and
            w.last_heartbeat_at > ^cutoff,
        order_by: [asc: w.active_sessions, asc: w.ordinal]
    )
    |> Enum.filter(&(Worker.disk_fraction(&1) < high_watermark))
  end

  @doc "Mark pods that have stopped heartbeating as unhealthy, and say which."
  @spec sweep() :: [Worker.t()]
  def sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -lease_timeout_ms(), :millisecond)

    {_count, workers} =
      Repo.update_all(
        from(w in Worker, where: w.healthy and w.last_heartbeat_at < ^cutoff, select: w),
        set: [healthy: false, updated_at: DateTime.utc_now()]
      )

    workers || []
  end

  @doc "Stop placing on a pod. Running turns finish; the sessions then go dormant."
  @spec drain(Worker.t(), boolean()) :: {:ok, Worker.t()} | {:error, term()}
  def drain(%Worker{} = worker, draining? \\ true) do
    worker |> Worker.changeset(%{draining: draining?}) |> Repo.update()
  end

  @doc "Placement skips a pod above this fraction of its disk."
  @spec high_watermark() :: float()
  def high_watermark, do: Application.get_env(:troupe_plane, :disk_high_watermark, 0.80)

  @doc "Dormant caches are evicted above this fraction, down to below it."
  @spec low_watermark() :: float()
  def low_watermark, do: Application.get_env(:troupe_plane, :disk_low_watermark, 0.70)
end
