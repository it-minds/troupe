defmodule Troupe.Plane.FleetTest do
  @moduledoc """
  Presence, and what the plane does when it stops.

  A done item: a killed pod is marked unhealthy within 15 seconds. The lease is what
  makes that a number rather than a hope — a pod that cannot tell anyone it has died is
  the case this exists for.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Fleet, Harness, Sessions}
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

    eventually(fn -> not Fleet.get_worker(lost.id).healthy end)
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

  describe "a pod the operator removed" do
    # A scale-down from two pods to one: dev-1 was retired, the count came down past it,
    # and the StatefulSet removed it. Its row was kept for ever as draining before.
    setup do
      {:ok, profile} = Fleet.put_profile(%{name: "dev", replicas: 2})
      kept = pod("dev", 0)
      removed = pod("dev", 1)
      {:ok, _} = Fleet.retire(removed)
      {:ok, profile} = Fleet.put_profile(%{name: profile.name, replicas: 1})
      :ok = Fleet.retired("dev", 1)

      %{profile: profile, kept: kept, removed: removed}
    end

    test "is gone once it is quiet past its lease, and not before", context do
      refute Fleet.gone?(Fleet.get_worker(context.removed.id), context.profile)

      silence(context.removed, Fleet.lease_timeout_ms() + 1_000)
      assert Fleet.gone?(Fleet.get_worker(context.removed.id), context.profile)

      # A pod the operator still runs is broken when it is quiet, never gone.
      silence(context.kept, Fleet.lease_timeout_ms() + 1_000)
      refute Fleet.gone?(Fleet.get_worker(context.kept.id), context.profile)
    end

    test "is forgotten by the sweep once it is quiet past the drain's deadline", context do
      silence(context.removed, Fleet.lease_timeout_ms() + 1_000)
      assert Fleet.forget_gone() == []
      assert Fleet.get_worker(context.removed.id)

      silence(context.removed, Fleet.drain_deadline_ms() + 1_000)
      silence(context.kept, Fleet.drain_deadline_ms() + 1_000)

      assert [forgotten] = Fleet.forget_gone()
      assert forgotten.id == context.removed.id
      refute Fleet.get_worker(context.removed.id)

      # The pod still run keeps its row, however quiet: that one is the administrator's to
      # look at. And a sweep again forgets nothing twice.
      assert Fleet.get_worker(context.kept.id)
      assert Fleet.forget_gone() == []
      assert Enum.map(Fleet.list_workers("dev"), & &1.pod_name) == ["dev-0"]
    end

    test "is kept while it holds an active session, which the rescue has not yet reached",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])

      {:ok, session} =
        Sessions.create(%{
          id: "s-#{System.unique_integer([:positive])}",
          owner_id: ada.id,
          owner_subject: ada.subject,
          team_id: team.id,
          profile: "dev",
          state: "pending",
          epoch: 1
        })

      {:ok, _} = Sessions.place(session.id, context.removed)
      silence(context.removed, Fleet.drain_deadline_ms() + 1_000)

      assert Fleet.forget_gone() == []
      assert Fleet.get_worker(context.removed.id)
    end

    test "comes back as a new row when a pod enrols at that ordinal again", context do
      silence(context.removed, Fleet.drain_deadline_ms() + 1_000)
      assert [_] = Fleet.forget_gone()

      {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 2})
      again = pod("dev", 1)

      assert again.id != context.removed.id
      refute again.draining
      refute Fleet.gone?(again, Fleet.get_profile("dev"))
    end

    test "is listed as gone, since when it was last heard, and the pod still run is not",
         context do
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)
      root = Admin.actor_for(person("root@example.test", ["platform"]))

      silence(context.removed, Fleet.lease_timeout_ms() + 1_000)

      assert {:ok, profiles} = Admin.profiles_list(root)

      pods =
        profiles |> Enum.find(&(&1.name == "dev")) |> Map.fetch!(:pods) |> Map.new(&{&1.pod, &1})

      assert pods["dev-1"].gone
      assert DateTime.compare(pods["dev-1"].last_seen_at, DateTime.utc_now()) == :lt
      refute pods["dev-0"].gone
    end

    # `profiles.list`, what the desktop and the terminal read, says so too, and counts the
    # gone pod nowhere: not as room, not as a healthy pod, whatever its flags last said.
    test "is listed as gone to a person choosing a profile, and offers no room", context do
      _team = team_with_grant("engineering", "dev", name: "engineering")
      ada = person("ada@example.test", ["engineering"])
      # Its last flags healthy and not draining, as a row could be left: gone wins.
      Repo.update_all(from(w in Worker, where: w.id == ^context.removed.id),
        set: [healthy: true, draining: false]
      )

      silence(context.removed, Fleet.lease_timeout_ms() + 1_000)

      assert {:ok, %{"profiles" => [dev]}} =
               Harness.call("profiles.list", %{}, %{user: ada, platform_admin?: false})

      pods = Map.new(dev["pods"], &{&1["pod"], &1})
      assert pods["dev-1"]["gone"] == true
      assert pods["dev-0"]["gone"] == false
      assert dev["capacity"] == 4
      assert dev["healthy_pods"] == 1
    end

    test "of a profile the plane no longer has is gone too" do
      orphan = pod("old", 0)
      silence(orphan, Fleet.drain_deadline_ms() + 1_000)

      assert Enum.map(Fleet.forget_gone(), & &1.id) == [orphan.id]
    end
  end
end
