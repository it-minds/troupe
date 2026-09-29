defmodule Troupe.Plane.Fleet.Upgrade do
  @moduledoc """
  The plane's half of finishing a worker upgrade.

  A worker StatefulSet rolls `OnDelete`: a new image, env or volume is a new revision, and
  a pod keeps the old one until it is deleted, because it holds live sessions. Deleting it
  is the operator's, which has the grant; knowing when that is safe is the plane's, which
  alone knows when a pod holds nothing. So the work is split along that line
  (Decision 726):

    * the operator reports which pods run an older revision, each with its uid
      (`status.podsBehind`);
    * the plane drains such a pod once it holds no active session, and records the drain
      finished once the pod is draining and still holds none (the `troupe.dev/drained`
      annotation, with the revision the pod ran);
    * the operator deletes a recorded pod that is behind and no longer Ready, one at a
      time, and the StatefulSet makes it again on the new revision, with the same volume.

  One pod at a time here as well, the highest ordinal first: another is drained only once
  no pod behind is draining, so an upgrade takes at most one pod's room from a profile at
  a time. The drain is the one an administrator starts from the console (`Drain.pod/2`),
  in the background because it waits for the pod's answer; with no active session there is
  nothing for the pod to wait on.

  A pod that is always busy is not drained by this, and need not be: new sessions go to a
  pod on the current revision while one has room (`Troupe.Plane.Placement`), so the old
  pod's sessions go dormant in their own time and then it goes. A profile with one pod
  keeps giving that pod new sessions, having nowhere else to put them, and it rolls the
  first time every session on it is dormant; for the half-minute its replacement takes to
  start the profile has no pod, and a session opened then waits, as on a cold profile. An
  administrator who cannot wait drains it from the console, and the rest follows.

  Run by the scaler on its tick, for profiles the Kubernetes provisioner makes. It has no
  loop of its own: what did not happen on one tick is taken up on the next, from what the
  cluster and the database say then.
  """

  alias Troupe.Plane.{Drain, Fleet, Provision, Sessions}
  alias Troupe.Plane.Fleet.{Profile, Provisioner, Worker}

  require Logger

  @doc """
  One step of a profile's upgrade: which pods are behind, the next one to drain, and the
  drains to record.

  `:skipped` for a profile with no `WorkerProfile` to read, which is one another
  provisioner makes, one the operator has not written yet, or a plane with no cluster.
  `opts[:drain]` is what starts a drain, for a test that has no pod to ask.
  """
  @spec step(Profile.t(), keyword()) :: map() | :skipped
  def step(%Profile{} = profile, opts \\ []) do
    with Provisioner.Kubernetes <- Provisioner.for(profile),
         {:ok, %{behind: reported, drained: recorded}} <- Provision.upgrade(profile) do
      advance(profile, reported, recorded, Keyword.get(opts, :drain, &drain/1))
    else
      _not_here -> :skipped
    end
  end

  defp advance(profile, reported, recorded, drain) do
    revisions = Map.new(reported, &{{&1.pod, &1.uid}, &1.revision})
    behind = Enum.filter(Fleet.list_workers(profile.name), &behind?(&1, revisions))
    :ok = Fleet.mark_upgrade_pending(profile.name, Enum.map(behind, & &1.id))

    counts = Sessions.active_counts_by_worker(profile.name)
    idle = Enum.filter(behind, &(Map.get(counts, &1.id, 0) == 0))

    # Read before this step starts anything, so a drain started now is recorded on a later
    # step, from a count taken after it began: a session placed in the moment before the
    # pod was marked is then on the count, and the pod is not called empty while the
    # session is still being sealed.
    finished =
      for %Worker{draining: true} = worker <- idle,
          revision = Map.get(revisions, {worker.pod_name, worker.pod_uid}),
          is_binary(revision),
          into: %{},
          do: {worker.pod_name, revision}

    started = if Enum.any?(behind, & &1.draining), do: nil, else: start(idle, drain)

    if finished != recorded, do: record(profile, finished)

    %{behind: Enum.map(behind, & &1.pod_name), draining: started, drained: finished}
  end

  # By name and uid both. The name alone would also match the pod that replaced the one
  # the operator reported, which enrols under the same name and can do so before the
  # operator's next pass; draining that one would leave a current pod drained for good.
  defp behind?(%Worker{pod_uid: uid, pod_name: pod}, revisions) when is_binary(uid),
    do: Map.has_key?(revisions, {pod, uid})

  defp behind?(_worker, _revisions), do: false

  # The highest ordinal first, as a StatefulSet takes them. Marked here, so the next
  # placement and the next step see it at once; the pod is told in the background.
  defp start(idle, drain) do
    case Enum.max_by(idle, & &1.ordinal, fn -> nil end) do
      nil ->
        nil

      worker ->
        {:ok, worker} = Fleet.drain(worker, true)

        Logger.info(
          "troupe plane: draining #{worker.pod_name} for an upgrade, it holds no session"
        )

        drain.(worker)
        worker.pod_name
    end
  end

  defp drain(worker) do
    Task.start(fn ->
      case Drain.pod(worker) do
        {:ok, _report} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "troupe plane: #{worker.pod_name} did not drain for an upgrade: #{inspect(reason)}"
          )
      end
    end)
  end

  # Written only when it changed. A write that failed is written again on the next step,
  # which computes the same record from the same facts.
  defp record(profile, finished) do
    case Provision.record_drained(profile, finished) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "troupe plane: could not record #{profile.name}'s finished drains: #{inspect(reason)}"
        )
    end
  end
end
