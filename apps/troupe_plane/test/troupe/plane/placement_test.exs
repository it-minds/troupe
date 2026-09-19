defmodule Troupe.Plane.PlacementTest do
  @moduledoc """
  Where a session goes, and what happens when there is nowhere for it.

  Capacity is one of the two things in the plane that must not be decided in two places
  at once. These prove the decision on one replica; `Troupe.Plane.ClusterTest` proves it
  across two.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Fleet, Placement, Sessions, Singleton}

  setup do
    start_supervised!(Singleton)
    :ok
  end

  defp profile(name, pods, opts \\ []) do
    {:ok, _} = Fleet.put_profile(%{name: name, replicas: pods, sessions_per_pod: Keyword.get(opts, :per_pod, 4)})

    for ordinal <- 0..(pods - 1)//1 do
      {:ok, worker} =
        Fleet.enrol(%{
          profile: name,
          ordinal: ordinal,
          pod_name: "troupe-w-#{name}-#{ordinal}",
          namespace: "troupe-w-#{name}",
          endpoint: "https://#{ordinal}.#{name}.workers.test",
          capacity: Keyword.get(opts, :per_pod, 4),
          disk_total_bytes: 100,
          disk_used_bytes: Keyword.get(opts, :disk_used, 0)
        })

      worker
    end
  end

  defp session(id, profile) do
    {:ok, s} = Sessions.create(%{id: id, owner_subject: "idp|alice", profile: profile})
    s
  end

  test "a session lands on a healthy pod, and the pod's count goes up" do
    [_first, _second] = profile("dev", 2)
    session("s-1", "dev")

    assert {:ok, %{worker: worker}} = Placement.reserve("dev", "s-1")
    assert worker.profile == "dev"

    assert Sessions.get("s-1").worker_id == worker.id
    assert Placement.inspect_state("dev").used == 1
  end

  test "sessions spread across pods rather than filling one" do
    profile("dev", 2, per_pod: 4)

    placements =
      for n <- 1..4 do
        session("s-#{n}", "dev")
        {:ok, %{worker: worker}} = Placement.reserve("dev", "s-#{n}")
        worker.ordinal
      end

    # Two pods, four sessions: two each. Spreading is what keeps one pod's loss from
    # taking most of the work with it.
    assert Enum.frequencies(placements) == %{0 => 2, 1 => 2}
  end

  test "a profile with no room refuses, and says why" do
    profile("dev", 1, per_pod: 2)

    for n <- 1..2 do
      session("s-#{n}", "dev")
      assert {:ok, _} = Placement.reserve("dev", "s-#{n}")
    end

    session("s-3", "dev")
    assert {:error, :at_capacity} = Placement.reserve("dev", "s-3")
    assert is_nil(Sessions.get("s-3").worker_id)
  end

  test "a profile with no pod at all says that, and not that the pods are full" do
    # Zero pods and full pods want opposite things done about them: one needs somebody to
    # find out why the pods will not start, the other needs replicas. Both answered
    # `:at_capacity` — and "every pod is full" about a pod that was stuck `Pending` is a
    # sentence that sends a person to the wrong place entirely.
    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 1, sessions_per_pod: 4})
    session("s-1", "dev")

    assert {:error, :no_healthy_worker} = Placement.reserve("dev", "s-1")
    assert is_nil(Sessions.get("s-1").worker_id)
  end

  test "releasing a slot makes room again" do
    profile("dev", 1, per_pod: 1)
    session("s-1", "dev")
    session("s-2", "dev")

    assert {:ok, _} = Placement.reserve("dev", "s-1")
    assert {:error, :at_capacity} = Placement.reserve("dev", "s-2")

    :ok = Placement.release("dev", "s-1")

    assert {:ok, _} = Placement.reserve("dev", "s-2")
  end

  test "a slot given back by a session that was already unplaced is still given back" do
    profile("dev", 1, per_pod: 1)
    session("s-1", "dev")
    session("s-2", "dev")

    assert {:ok, _} = Placement.reserve("dev", "s-1")

    # The order `strand/2` used to do these in: dormant first, which clears `worker_id`,
    # and then release — which gives a slot back only where it finds one to clear. The
    # pod stayed charged for a session that was no longer on it, and a profile whose
    # count only ever goes up is full for ever while the database says it is empty.
    {:ok, _} = Sessions.dormant("s-1")
    :ok = Placement.release("dev", "s-1")

    assert {:ok, _} = Placement.reserve("dev", "s-2")
  end

  test "a count that drifted upward does not make a profile full for ever" do
    profile("dev", 1, per_pod: 1)
    session("s-1", "dev")

    # However it happened — this is the state, and the question is whether the plane can
    # get out of it. Before recounting on the refusal path it could not: nothing reloads
    # while every pod is one this actor has already seen, so the drift was permanent
    # until the plane restarted.
    assert {:ok, _} = Placement.reserve("dev", "s-1")
    {:ok, _} = Sessions.unplace("s-1")
    {:ok, _} = Sessions.dormant("s-1")

    session("s-2", "dev")
    assert {:ok, _} = Placement.reserve("dev", "s-2")
  end

  test "a draining pod takes nothing new" do
    [first, second] = profile("dev", 2, per_pod: 4)
    {:ok, _} = Fleet.drain(second)

    for n <- 1..4 do
      session("s-#{n}", "dev")
      {:ok, %{worker: worker}} = Placement.reserve("dev", "s-#{n}")
      assert worker.id == first.id, "a draining pod was placed on"
    end
  end

  test "a draining pod is not a reader either: it is out of its Service's endpoints" do
    [first, second] = profile("dev", 2, per_pod: 4)
    {:ok, _} = Fleet.drain(second)

    # Even when it is the pod with the session's cache.
    assert {:ok, worker} = Placement.reader("dev", second.id)
    assert worker.id == first.id

    {:ok, _} = Fleet.drain(first)
    assert {:error, :no_healthy_worker} = Placement.reader("dev", nil)
  end

  test "a pod above the disk high watermark takes nothing new" do
    # A session that cannot write its workspace is worse than one that waited for room.
    [full, _room] = profile("dev", 2, per_pod: 4)
    {:ok, _} = Fleet.heartbeat(full, %{disk_used_bytes: 95, disk_total_bytes: 100})

    session("s-1", "dev")
    assert {:ok, %{worker: worker}} = Placement.reserve("dev", "s-1")
    refute worker.id == full.id
  end

  test "a pod that has stopped heartbeating takes nothing new" do
    [quiet, _alive] = profile("dev", 2, per_pod: 4)

    stale = DateTime.add(DateTime.utc_now(), -Fleet.lease_timeout_ms() * 2, :millisecond)
    Repo.update_all(from(w in Fleet.Worker, where: w.id == ^quiet.id), set: [last_heartbeat_at: stale])

    session("s-1", "dev")
    assert {:ok, %{worker: worker}} = Placement.reserve("dev", "s-1")
    refute worker.id == quiet.id
  end

  test "reading a dormant session prefers the pod with its cache, and consumes no capacity" do
    [first, second] = profile("dev", 2, per_pod: 1)

    session("s-1", "dev")
    {:ok, _} = Placement.reserve("dev", "s-1")

    assert {:ok, worker} = Placement.reader("dev", second.id)
    assert worker.id == second.id

    # A reader is a short-lived process with no agent and no model call, so it does not
    # take a slot: the profile still has exactly one in use.
    assert Placement.inspect_state("dev").used == 1

    assert {:ok, _} = Placement.reader("dev", first.id)
  end

  test "the actor reloads what it granted, so a replica losing it changes nothing" do
    profile("dev", 1, per_pod: 2)
    session("s-1", "dev")
    assert {:ok, _} = Placement.reserve("dev", "s-1")

    # Kill the actor the way a replica going away would.
    pid = :global.whereis_name({Placement, "dev"})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    # The next caller starts it again — here, or on a survivor — and it reads back
    # exactly what was granted, because the reservation was written before it was
    # returned.
    assert Placement.inspect_state("dev").used == 1

    session("s-2", "dev")
    assert {:ok, _} = Placement.reserve("dev", "s-2")

    session("s-3", "dev")
    assert {:error, :at_capacity} = Placement.reserve("dev", "s-3")
  end

  test "fifty concurrent creates on one replica fill the profile exactly once" do
    profile("dev", 5, per_pod: 4)

    # The rows are written first and only the placement is raced: placement *is* the
    # serialisation point of a create, and a task that held a database connection while
    # it blocked on the actor would deadlock the pool rather than test it.
    for n <- 1..50, do: session("s-#{n}", "dev")

    results =
      1..50
      |> Task.async_stream(fn n -> Placement.reserve("dev", "s-#{n}") end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    granted = Enum.count(results, &match?({:ok, _}, &1))
    refused = Enum.count(results, &match?({:error, :at_capacity}, &1))

    assert granted == 20
    assert refused == 30

    # And no pod is over its own cap, which the total alone would not prove.
    for {_worker_id, used} <- Placement.inspect_state("dev").capacities do
      assert used <= 4
    end
  end
end
