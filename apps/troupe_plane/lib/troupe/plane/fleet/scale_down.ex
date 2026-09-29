defmodule Troupe.Plane.Fleet.ScaleDown do
  @moduledoc """
  Lowering a profile's count without taking a session with the pod.

  A StatefulSet removes its highest ordinals, and a pod takes with it whatever it holds:
  the session's process, a turn in flight, and the workspace's files since its last
  archive, five minutes of them at most. Its clients saw the session vanish, and the
  sweeper marked it dormant a lease later from its last seal. So the count comes down only
  past pods that hold nothing, and the scaler empties them first (Decision 731):

    * once the profile has wanted fewer workers for the grace period, the pods above the
      count it wants are marked retiring, which also stops placement on them, and drained:
      the drain an administrator starts (`Drain.pod/2`), in the background
      (`Drain.start/2`, as an upgrade's is). The pod lets a running turn finish, then puts
      every session to sleep: sealed, archived, uploaded, reported;
    * the count comes down, from the top, past each pod that is retiring, draining and
      holds no active session on a count taken before this step, and past an ordinal no
      pod has enrolled at when it is to come down that far.

  **A pod with a turn in flight goes when the turn has finished, or when the drain
  timeout has passed, whichever is first.** At the timeout the pod cancels the turn, seals
  everything up to the cancellation and puts the session to sleep. The bound is the same
  number the pods' `terminationGracePeriodSeconds` is set from, so a scale-down is never
  harsher to a turn than deleting the pod would be; without one, a session that never
  rests (an agent in a long loop, a question nobody answers) would keep a pod the profile
  does not need for as long as it went on, and nobody would be told. Nothing here retries:
  the pod is asked once, and each tick only reads the count. A pod the plane still counts
  a session on is never removed: if the pod says it is empty while the index still puts
  a session on it, the drain's warning names the session, and the pod stays until that
  session is dormant.

  **A scale-down that has started is finished.** A drained pod takes no session until it
  restarts (Decision 633), so when the sessions come back while it drains, the count
  still comes down past it once it is empty, and the next tick asks for the pod again,
  which the StatefulSet starts fresh. Left in place, it would have been counted as room
  it cannot give, and a session could wait for it for ever. Retiring is what tells this
  drain from an administrator's, which is left alone unless its pod is above the count
  the profile wants. A count that grows while a retiring pod still drains grows past it;
  that pod goes with the next scale-down that reaches it.

  For profiles the Kubernetes provisioner makes. Elsewhere a lower count removes no
  machine, and the scaler writes it as it is.
  """

  alias Troupe.Plane.{Drain, Fleet, Sessions}
  alias Troupe.Plane.Fleet.{Profile, Provisioner, Worker}

  require Logger

  @doc """
  One step of a profile's scale-down: the count it may have now, the pods this step began
  to retire, and the pods that count leaves out.

  `plan` is the scaler's: `have` is the count the profile has and `want` the one it has
  settled on. `:skipped` for a profile another provisioner makes.
  """
  @spec step(Profile.t(), %{want: non_neg_integer(), have: non_neg_integer()}) ::
          %{count: non_neg_integer(), retiring: [String.t()], removed: [String.t()]} | :skipped
  def step(%Profile{} = profile, %{want: want, have: have}) do
    case Provisioner.for(profile) do
      Provisioner.Kubernetes -> advance(profile, min(want, have), have)
      _elsewhere -> :skipped
    end
  end

  defp advance(profile, target, have) do
    # The pods a set of `have` runs. A row above that is a pod already removed, kept as a
    # removed pod's row always is.
    workers = profile.name |> Fleet.list_workers() |> Enum.filter(&(&1.ordinal < have))

    # Read before this step retires anything, so a pod retired now goes on a later step,
    # from a count taken after it was marked: a session placed on it in the moment before
    # is then on the count, and the pod is not called empty while that session is sealed.
    counts = Sessions.active_counts_by_worker(profile.name)
    count = lowest_empty(Map.new(workers, &{&1.ordinal, &1}), counts, target, have)

    retiring =
      for %Worker{retiring: false} = worker <- workers, worker.ordinal >= target do
        retire(worker)
      end

    %{
      count: count,
      retiring: retiring,
      removed: for(worker <- workers, worker.ordinal >= count, do: worker.pod_name)
    }
  end

  # From the top down, because a StatefulSet removes nothing else, and the first ordinal
  # that is not empty stops it.
  defp lowest_empty(by_ordinal, counts, target, have) do
    (have - 1)..0//-1
    |> Enum.take_while(&empty?(Map.get(by_ordinal, &1), &1, counts, target))
    |> Enum.min(fn -> have end)
  end

  defp empty?(nil, ordinal, _counts, target), do: ordinal >= target

  defp empty?(%Worker{retiring: true, draining: true} = worker, _ordinal, counts, _target),
    do: Map.get(counts, worker.id, 0) == 0

  defp empty?(_worker, _ordinal, _counts, _target), do: false

  # Marked before the pod is told, so the next placement and the next step see it at once.
  # A pod that was draining already, because somebody drained it or an upgrade did, is
  # marked and not told again: its drain is running.
  defp retire(%Worker{} = worker) do
    {:ok, retired} = Fleet.retire(worker)

    unless worker.draining do
      Logger.info("troupe plane: draining #{worker.pod_name} for a scale-down")
      Drain.start(retired, "for a scale-down")
    end

    worker.pod_name
  end
end
