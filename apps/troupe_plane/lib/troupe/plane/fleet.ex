defmodule Troupe.Plane.Fleet do
  @moduledoc """
  What is running, and how much room it has.

  Presence is a heartbeat and nothing else. A pod that has stopped heartbeating past
  the lease timeout is unhealthy, and an unhealthy pod is not placed on — the plane does
  not wait to be told, because the interesting failure is a pod that cannot tell anyone
  anything.
  """

  import Ecto.Query

  alias Troupe.Plane.Fleet.{Hosts, Profile, Provisioner, Worker}
  alias Troupe.Plane.Memory
  alias Troupe.Plane.Repo
  alias Troupe.Plane.Sessions.Session

  # Past this with no heartbeat a pod is presumed lost. Fifteen seconds is the done
  # item's number, and heartbeats are every five.
  @lease_timeout_ms 15_000

  # Placement skips a pod above this fraction of its disk: the worker's own high mark,
  # past which it puts its quietest sessions to sleep.
  @high_watermark 0.80

  @doc "How long a pod may go quiet before it is presumed lost."
  @spec lease_timeout_ms() :: pos_integer()
  def lease_timeout_ms, do: Application.get_env(:troupe_plane, :lease_timeout_ms, @lease_timeout_ms)

  # -- profiles ---------------------------------------------------------------

  @doc "Record what a profile is, so placement need not ask Kubernetes."
  @spec put_profile(map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def put_profile(attrs) do
    name = attrs[:name] || attrs["name"]
    before = Repo.get(Profile, name)

    (before || %Profile{})
    |> Profile.changeset(attrs)
    |> Repo.insert_or_update()
    |> chain_moved(before)
  end

  # A profile that extends another now, or another one, or none: the memory its running
  # sessions and its descendants' read comes from a chain that changed, so they are told at
  # once, as a save of a document in it tells them, and read it from their next turn.
  defp chain_moved({:ok, %Profile{extends: now} = profile} = saved, %Profile{extends: was})
       when now != was do
    _told = Memory.announce(profile.name)
    saved
  end

  defp chain_moved(saved, _before), do: saved

  @doc """
  Record a profile as the cluster holds it, with the generation it was read at: GitOps
  mode's write, where the resource comes first and the row follows (Decision 736).
  """
  @spec follow_profile(map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def follow_profile(attrs) do
    before = Repo.get(Profile, attrs.name)

    (before || %Profile{})
    |> Profile.cluster_changeset(attrs)
    |> Repo.insert_or_update()
    |> chain_moved(before)
  end

  @doc "One profile, or `nil`."
  @spec get_profile(String.t()) :: Profile.t() | nil
  def get_profile(name), do: Repo.get(Profile, name)

  @doc "Every profile."
  @spec list_profiles() :: [Profile.t()]
  def list_profiles, do: Repo.all(from p in Profile, order_by: p.name)

  @doc """
  Remove a profile's record, and its memory document with it, so a profile made again under
  the name starts with none. The custom resource is the operator's business.
  """
  @spec delete_profile(String.t()) :: :ok
  def delete_profile(name) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Memory.forget(name)
        Repo.delete_all(from p in Profile, where: p.name == ^name)
        :ok
      end)

    :ok
  end

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
    high_watermark = Keyword.get(opts, :high_watermark, @high_watermark)
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

  @doc """
  A pod's control connection has gone, so stop placing sessions on it.

  The sweeper already does this after the heartbeat lease expires, which was enough when
  a pod only went away because somebody drained it. It is not enough now that the plane
  scales profiles itself: a worker removed by a scale-down stops heartbeating and stays
  *placeable* for the rest of its lease, so the next `session.create` is placed on a pod
  that is not there and fails with "the pod did not accept the session".

  The plane learns this the instant the socket closes, which is a great deal sooner than
  a lease. Health only governs placement — the sessions the pod was holding are the
  sweeper's business and are stranded on its schedule, not this one.

  **`enrolled_at` is the fence, and it is load-bearing.** A pod whose plane replica dies
  reconnects to the survivor, and the two events race: the new connection enrols and marks
  the row healthy, and then the old connection's teardown arrives and marks it unhealthy
  again. Nothing recovers from that until the pod's next heartbeat, and in between every
  create is refused with `no_healthy_worker` — a failover that looks exactly like an
  outage. So a teardown may only mark the row it is actually about: one that has not been
  enrolled since. Without the fence, "costs nothing if the connection comes straight back"
  was false precisely when the connection came straight back.
  """
  @spec disconnected(String.t(), String.t(), DateTime.t()) :: :ok
  def disconnected(namespace, pod_name, enrolled_at) do
    Repo.update_all(
      from(w in Worker,
        where:
          w.namespace == ^namespace and w.pod_name == ^pod_name and w.healthy and
            w.enrolled_at <= ^enrolled_at
      ),
      set: [healthy: false, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  Mark pods that have stopped heartbeating as unhealthy, and say which.

  Stopping placement, which is the easy half. The other half — what becomes of the
  sessions such a pod was believed to be holding — is `lost/0`, because they are two
  questions: a pod with nothing on it needs nothing done about it, and a pod that was
  marked unhealthy an hour ago still holds whatever it held.
  """
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

  @doc """
  Pods past their lease that are still believed to be holding sessions.

  Nothing ever did anything about these. They stayed `active`, pointing at a worker that
  was gone, and opening one took the already-running branch — it hands the client an
  endpoint and never tells the pod to restore — so `subscribe` answered `not_found` for as
  long as anybody cared to retry. No timeout expired and no retry helped.

  It only ever looked handled because a pod that comes *back* reconciles what it holds on
  re-enrolment, and until the plane scaled profiles itself a pod nearly always came back.
  A pod removed by a scale-down does not.

  Health is not in the question. A worker marked unhealthy the moment its socket closed
  is exactly the one whose sessions need rescuing, and asking only about healthy ones
  would skip it. Idempotent because a session that has been marked dormant is not on a
  worker: once rescued, there is nothing here to find.
  """
  @spec lost() :: [Worker.t()]
  def lost do
    cutoff = DateTime.add(DateTime.utc_now(), -lease_timeout_ms(), :millisecond)

    Repo.all(
      from(w in Worker,
        join: s in Session,
        on: s.worker_id == w.id and s.state == "active",
        where: w.last_heartbeat_at < ^cutoff,
        distinct: w.id,
        select: w
      )
    )
  end

  @doc """
  How long a drain lets a pod's running turns finish, which is also how long the plane
  keeps the row of a pod its substrate no longer runs before it forgets it.
  """
  @spec drain_deadline_ms() :: pos_integer()
  def drain_deadline_ms,
    do: Application.get_env(:troupe_plane, :drain_timeout_seconds, 300) * 1_000

  @doc """
  Whether the substrate still has this pod: for a profile the cluster makes, an ordinal
  below the count the profile's resource asks for, which is what the operator's
  StatefulSet runs; for a registered host, a host of that name still registered for the
  profile. A pod of a profile the plane no longer has is had by nobody.

  Not health. A pod that is listed and silent is broken, or starting, and is the
  administrator's to look at; one that is not listed was removed, and only waits to be
  forgotten (`forget_gone/0`).
  """
  @spec listed?(Worker.t(), Profile.t() | nil) :: boolean()
  def listed?(%Worker{}, nil), do: false

  def listed?(%Worker{} = worker, %Profile{} = profile) do
    if Provisioner.for(profile) == Provisioner.SSH do
      Enum.any?(Hosts.for_profile(profile.name), &(&1.name == worker.pod_name))
    else
      is_integer(worker.ordinal) and worker.ordinal < (profile.replicas || 0)
    end
  end

  @doc """
  Whether a pod is gone: its substrate no longer has it and it has not been heard from
  for longer than its lease. Shown as gone, since when it was last heard, until
  `forget_gone/0` drops the row; never offered a drain, and never counted as somewhere a
  drained pod's sessions could go.
  """
  @spec gone?(Worker.t(), Profile.t() | nil) :: boolean()
  def gone?(%Worker{} = worker, profile) do
    cutoff = DateTime.add(DateTime.utc_now(), -lease_timeout_ms(), :millisecond)
    DateTime.compare(worker.last_heartbeat_at, cutoff) == :lt and not listed?(worker, profile)
  end

  @doc """
  A profile's room right now, as a person choosing it is told: every pod, which of them
  are gone, and the pods that count, neither draining nor gone, with the places they
  hold at most and the sessions they run now. `profiles.list` and `profile.get` both
  answer from this, so the listing and the profile's page cannot disagree.

  A gone pod is listed until the sweep forgets it and counts for nothing, whatever its
  last flags said. A draining pod is listed, so a person can see it, and counts for
  nothing either: it takes no session and is out of its Service, so it is neither room
  nor health, and the sessions still on it are on their way elsewhere.
  """
  @spec room(String.t(), Profile.t() | nil) :: %{
          workers: [Worker.t()],
          gone: MapSet.t(Ecto.UUID.t()),
          placeable: [Worker.t()],
          capacity: non_neg_integer(),
          active_sessions: non_neg_integer()
        }
  def room(name, profile) do
    workers = list_workers(name)
    gone = MapSet.new(Enum.filter(workers, &gone?(&1, profile)), & &1.id)
    placeable = Enum.reject(workers, &(&1.draining or MapSet.member?(gone, &1.id)))

    %{
      workers: workers,
      gone: gone,
      placeable: placeable,
      capacity: Enum.sum(Enum.map(placeable, & &1.capacity)),
      active_sessions: Enum.sum(Enum.map(placeable, & &1.active_sessions))
    }
  end

  @doc """
  Forget the pods that are gone for good, and say which.

  A row whose pod the substrate no longer has, that has not been heard from for longer
  than a drain's deadline, and that holds no active session. A scale-down's pods were
  kept for ever before this, `draining` and unhealthy, and every listing showed them as
  pods stuck mid-drain. The deadline is the drain's own, so a pod that is still being
  drained, or one whose sessions the sweep has not yet rescued, is never dropped from
  under it; and a pod that comes back at the name enrols afresh, as it always could.

  Asked again in the delete, so a pod that enrolled between the read and the write is
  not the row that goes.
  """
  @spec forget_gone() :: [Worker.t()]
  def forget_gone do
    cutoff = DateTime.add(DateTime.utc_now(), -drain_deadline_ms(), :millisecond)

    quiet =
      Repo.all(
        from(w in Worker,
          as: :worker,
          where: w.last_heartbeat_at < ^cutoff,
          where:
            not exists(
              from(s in Session,
                where: s.worker_id == parent_as(:worker).id and s.state == "active",
                select: 1
              )
            )
        )
      )

    profiles = quiet |> Enum.map(& &1.profile) |> Enum.uniq() |> Map.new(&{&1, get_profile(&1)})
    gone = Enum.reject(quiet, &listed?(&1, profiles[&1.profile]))
    ids = Enum.map(gone, & &1.id)

    {_count, forgotten} =
      Repo.delete_all(
        from(w in Worker, where: w.id in ^ids and w.last_heartbeat_at < ^cutoff, select: w)
      )

    forgotten || []
  end

  @doc "Stop placing on a pod. Running turns finish; the sessions then go dormant."
  @spec drain(Worker.t(), boolean()) :: {:ok, Worker.t()} | {:error, term()}
  def drain(%Worker{} = worker, draining? \\ true) do
    worker |> Worker.changeset(%{draining: draining?}) |> Repo.update()
  end

  @doc """
  Stop placing on a pod because a scale-down is removing it (Decision 731).

  Draining, and marked as the scaler's own drain: the scaler lowers the count past a
  retiring pod once it holds nothing, whatever the profile wants by then, and leaves a pod
  drained for any other reason alone.
  """
  @spec retire(Worker.t()) :: {:ok, Worker.t()} | {:error, term()}
  def retire(%Worker{} = worker) do
    worker |> Worker.changeset(%{draining: true, retiring: true}) |> Repo.update()
  end

  @doc """
  The count has come down to `count`, so the pods above it are gone and retire no more.

  Their rows stay until the sweep forgets them, once they have been quiet past a drain's
  deadline (`forget_gone/0`); until then a listing says they are gone. A pod that comes
  back at one of those ordinals enrols afresh.
  """
  @spec retired(String.t(), non_neg_integer()) :: :ok
  def retired(profile, count) do
    Repo.update_all(
      from(w in Worker, where: w.profile == ^profile and w.ordinal >= ^count and w.retiring),
      set: [retiring: false, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  Record which of a profile's pods run an older revision, by worker id; every other pod
  of the profile does not.

  What placement reads to put a new session on a pod that is current while one has room
  (Decision 726). Written where it changes and nowhere else, since it is asked every tick.
  """
  @spec mark_upgrade_pending(String.t(), [Ecto.UUID.t()]) :: :ok
  def mark_upgrade_pending(profile, worker_ids) do
    Repo.update_all(
      from(w in Worker,
        where: w.profile == ^profile and w.id in ^worker_ids and not w.upgrade_pending
      ),
      set: [upgrade_pending: true, updated_at: DateTime.utc_now()]
    )

    Repo.update_all(
      from(w in Worker,
        where: w.profile == ^profile and w.id not in ^worker_ids and w.upgrade_pending
      ),
      set: [upgrade_pending: false, updated_at: DateTime.utc_now()]
    )

    :ok
  end
end
