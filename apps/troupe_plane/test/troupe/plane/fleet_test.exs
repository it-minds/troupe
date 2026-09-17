defmodule Troupe.Plane.FleetTest do
  @moduledoc """
  Presence, and what the plane does when it stops.

  A done item: a killed pod is marked unhealthy within 15 seconds. The lease is what
  makes that a number rather than a hope — a pod that cannot tell anyone it has died is
  the case this exists for.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Fleet
  alias Troupe.Plane.Fleet.{Sweeper, Worker}

  defp pod(profile, ordinal, opts \\ []) do
    {:ok, worker} =
      Fleet.enrol(%{
        profile: profile,
        ordinal: ordinal,
        pod_name: "#{profile}-#{ordinal}",
        namespace: "troupe-w-#{profile}",
        capacity: Keyword.get(opts, :capacity, 4),
        disk_total_bytes: 100,
        disk_used_bytes: Keyword.get(opts, :disk_used, 0)
      })

    worker
  end

  defp silence(worker, ago_ms) do
    at = DateTime.add(DateTime.utc_now(), -ago_ms, :millisecond)
    Repo.update_all(from(w in Worker, where: w.id == ^worker.id), set: [last_heartbeat_at: at])
  end

  test "the lease is fifteen seconds, which is the done item's number" do
    assert Fleet.lease_timeout_ms() == 15_000
  end

  test "a pod that keeps heartbeating stays placeable" do
    worker = pod("dev", 0)
    {:ok, _} = Fleet.heartbeat(worker, %{active_sessions: 1, disk_used_bytes: 10})

    assert Fleet.placeable("dev") |> Enum.map(& &1.id) == [worker.id]
  end

  test "a pod past the lease is swept, and stops being placeable" do
    alive = pod("dev", 0)
    lost = pod("dev", 1)

    silence(lost, Fleet.lease_timeout_ms() + 1_000)

    assert [swept] = Sweeper.sweep()
    assert swept.id == lost.id

    refute Fleet.get_worker(lost.id).healthy
    assert Fleet.placeable("dev") |> Enum.map(& &1.id) == [alive.id]
  end

  test "sweeping twice marks nothing twice" do
    lost = pod("dev", 0)
    silence(lost, Fleet.lease_timeout_ms() + 1_000)

    assert [_] = Sweeper.sweep()
    assert [] = Sweeper.sweep()
  end

  test "the sweeper runs on its own, well inside the lease" do
    lost = pod("dev", 0)
    silence(lost, Fleet.lease_timeout_ms() + 1_000)

    start_supervised!({Sweeper, interval_ms: 50})

    eventually(fn -> not Fleet.get_worker(lost.id).healthy end, "the pod was never marked unhealthy")
  end

  test "a pod that comes back is the same pod, with its sessions cleared" do
    worker = pod("dev", 0)
    {:ok, _} = Fleet.heartbeat(worker, %{active_sessions: 3})

    # A restart: same namespace, same name, same disk. Whatever it was running did not
    # survive, so the count starts again.
    {:ok, again} = Fleet.enrol(%{profile: "dev", ordinal: 0, pod_name: "dev-0", namespace: "troupe-w-dev", capacity: 4})

    assert again.id == worker.id
    assert again.active_sessions == 0
    assert again.healthy
  end

  test "a socket closing stops placement" do
    worker = pod("dev", 0)
    assert Fleet.placeable("dev") |> Enum.map(& &1.id) == [worker.id]

    :ok = Fleet.disconnected(worker.namespace, worker.pod_name, worker.enrolled_at)

    refute Fleet.get_worker(worker.id).healthy
    assert Fleet.placeable("dev") == []
  end

  test "a teardown that arrives after the pod came back leaves it alone" do
    worker = pod("dev", 0)

    # A plane replica dies. The pod reconnects to the survivor and enrols there — and only
    # then does the dead replica's teardown reach the database.
    {:ok, again} =
      Fleet.enrol(%{
        profile: "dev",
        ordinal: 0,
        pod_name: "dev-0",
        namespace: "troupe-w-dev",
        capacity: 4
      })

    assert again.healthy

    :ok = Fleet.disconnected(worker.namespace, worker.pod_name, worker.enrolled_at)

    # The teardown is about an enrolment this row has moved past, so it is not this row's
    # news. Without the fence the pod is unhealthy here, nothing recovers it until its next
    # heartbeat, and in between every create is refused with `no_healthy_worker` — a
    # failover that looks exactly like an outage.
    assert Fleet.get_worker(worker.id).healthy
    assert Fleet.placeable("dev") |> Enum.map(& &1.id) == [worker.id]

    # And a teardown for the enrolment that *is* current still lands.
    :ok = Fleet.disconnected(again.namespace, again.pod_name, again.enrolled_at)
    refute Fleet.get_worker(worker.id).healthy
  end

  defp eventually(predicate, message, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if predicate.(), do: :ok, else: Process.sleep(25)
    end)
    |> Enum.find(fn
      :ok -> true
      _ -> System.monotonic_time(:millisecond) > deadline
    end)
    |> case do
      :ok -> :ok
      _ -> flunk(message)
    end
  end
end
