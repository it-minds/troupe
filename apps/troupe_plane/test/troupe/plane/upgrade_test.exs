defmodule Troupe.Plane.UpgradeTest do
  @moduledoc """
  The plane's half of finishing a worker upgrade (Decision 726).

  The operator reports the pods behind in the `WorkerProfile`'s status, by name, uid and
  revision; the plane drains one once it holds no active session and records the drain
  finished in an annotation, which is what the operator deletes a pod on. The cluster
  here is `FakeWorkerProfiles`, which answers with the status a test gives it and keeps
  what the plane applies; the pods are rows enrolled the way a pod's own token enrols
  them, uid included. What starts a drain is replaced by a message, because there is no
  pod to ask: what is under test is which pod, and when.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Enrolment, FakeWorkerProfiles, Fleet, Sessions}
  alias Troupe.Plane.Fleet.Upgrade
  alias Troupe.WorkerProfile

  setup do
    {:ok, profile} = Fleet.put_profile(%{name: "dev", replicas: 3, sessions_per_pod: 4})
    %{profile: profile}
  end

  describe "which pod is drained" do
    test "the highest ordinal behind that holds no session, and only that one", context do
      workers = pods(3)
      behind(%{0 => "a", 1 => "a", 2 => "a"})
      busy(workers[2])

      assert %{behind: behind, draining: "troupe-w-dev-1"} = step(context.profile)
      assert Enum.sort(behind) == ["troupe-w-dev-0", "troupe-w-dev-1", "troupe-w-dev-2"]

      assert_received {:drain, "troupe-w-dev-1"}
      refute_received {:drain, _other}

      assert draining() == ["troupe-w-dev-1"]
      # Placement sees the three as behind at once.
      assert Enum.all?(Fleet.list_workers("dev"), & &1.upgrade_pending)
    end

    test "none while another pod behind is draining", context do
      workers = pods(2)
      behind(%{0 => "a", 1 => "a"})
      # An administrator's drain, still sealing the session on it.
      {:ok, _} = Fleet.drain(workers[1])
      busy(workers[1])

      assert %{draining: nil} = step(context.profile)
      refute_received {:drain, _pod}
      assert draining() == ["troupe-w-dev-1"]
    end

    test "never a pod on the current revision", context do
      pods(2)
      behind(%{})

      assert %{behind: [], draining: nil} = step(context.profile)
      refute_received {:drain, _pod}
      refute Enum.any?(Fleet.list_workers("dev"), & &1.upgrade_pending)
    end

    test "never the pod that replaced the one reported, under the same name", context do
      # The operator's last pass named ordinal 1's old pod. Its replacement has enrolled
      # since, under the same name, on the new revision, before the next pass said so.
      pods(2)

      FakeWorkerProfiles.start(%{
        "dev" => %{
          "podsBehind" => [%{"pod" => "troupe-w-dev-1", "uid" => "gone", "revision" => "a"}]
        }
      })

      assert %{behind: [], draining: nil} = step(context.profile)
      refute_received {:drain, _pod}
      assert draining() == []
    end

    test "with one pod, only once every session on it is dormant", context do
      # The pod has nowhere else to put its sessions, so it keeps taking them until it
      # rolls, and it rolls the first time it holds none.
      workers = pods(1)
      behind(%{0 => "a"})
      session = busy(workers[0])

      assert %{draining: nil} = step(context.profile)
      refute_received {:drain, _pod}

      {:ok, _} = Sessions.dormant(session.id)

      assert %{draining: "troupe-w-dev-0"} = step(context.profile)
      assert_received {:drain, "troupe-w-dev-0"}
    end
  end

  describe "what is recorded" do
    test "a pod behind that is draining and holds nothing, with the revision it runs", context do
      workers = pods(2)
      behind(%{0 => "a", 1 => "a"})
      {:ok, _} = Fleet.drain(workers[1])

      assert %{drained: %{"troupe-w-dev-1" => "troupe-w-dev-a"}} = step(context.profile)

      assert_received {FakeWorkerProfiles, :applied, "dev", applied, query}
      assert query["fieldManager"] == "troupe-plane-upgrade"
      assert WorkerProfile.drained(applied) == %{"troupe-w-dev-1" => "troupe-w-dev-a"}

      # The same record on the next step is not written again.
      step(context.profile)
      refute_received {FakeWorkerProfiles, :applied, _name, _applied, _query}
    end

    test "not a pod whose drain started on this step", context do
      # Its count was read before it was marked, so a session placed on it in that moment
      # would not be on it. The next step, from a count taken after, records it.
      pods(1)
      behind(%{0 => "a"})

      assert %{draining: "troupe-w-dev-0", drained: drained} = step(context.profile)
      assert drained == %{}
      refute_received {FakeWorkerProfiles, :applied, _name, _applied, _query}

      assert %{drained: %{"troupe-w-dev-0" => "troupe-w-dev-a"}} = step(context.profile)
    end

    test "not a pod still sealing a session", context do
      workers = pods(1)
      behind(%{0 => "a"})
      {:ok, _} = Fleet.drain(workers[0])
      busy(workers[0])

      assert %{drained: drained} = step(context.profile)
      assert drained == %{}
    end

    test "is taken away once the pod is no longer behind", context do
      # Replaced, so the operator's status no longer names it.
      pods(1)
      recorded = %{"troupe-w-dev-0" => "troupe-w-dev-a"}

      FakeWorkerProfiles.start(%{"dev" => %{"podsBehind" => []}}, %{
        "dev" => %{WorkerProfile.drained_annotation() => WorkerProfile.encode_drained(recorded)}
      })

      assert %{drained: drained} = step(context.profile)
      assert drained == %{}

      assert_received {FakeWorkerProfiles, :applied, "dev", applied, _query}
      assert get_in(applied, ["metadata", "annotations"]) == %{}
    end
  end

  test "a profile with no WorkerProfile to read is skipped", context do
    # A plane with no cluster, which is also what a profile the operator has not written
    # yet looks like once the read comes back `NotFound`.
    pods(1)
    assert Upgrade.step(context.profile, drain: fn _worker -> flunk("drained") end) == :skipped
  end

  # -- the world --------------------------------------------------------------

  defp step(profile) do
    test = self()
    Upgrade.step(profile, drain: &send(test, {:drain, &1.pod_name}))
  end

  # Pods enrolled as a pod's own token enrols them: the name and the uid are the token's.
  defp pods(count) do
    for ordinal <- 0..(count - 1), into: %{} do
      name = "troupe-w-dev-#{ordinal}"

      identity = %{
        profile: "dev",
        namespace: "troupe-w-dev",
        pod_name: name,
        pod_uid: "uid-" <> name,
        service_account: "troupe-worker"
      }

      {:ok, worker} = Enrolment.enrol(identity, %{"capacity" => 4, "disk_total_bytes" => 100})
      assert worker.pod_uid == "uid-" <> name
      {ordinal, worker}
    end
  end

  # What the operator's status says: these ordinals run the revision given, by uid.
  defp behind(revisions) do
    entries =
      for {ordinal, revision} <- Enum.sort(revisions) do
        name = "troupe-w-dev-#{ordinal}"
        %{"pod" => name, "uid" => "uid-" <> name, "revision" => "troupe-w-dev-" <> revision}
      end

    FakeWorkerProfiles.start(%{"dev" => %{"podsBehind" => entries}})
  end

  defp busy(worker) do
    id = "s-#{worker.ordinal}-#{System.unique_integer([:positive])}"
    {:ok, _} = Sessions.create(%{id: id, owner_subject: "idp|ada", profile: "dev"})
    {:ok, session} = Sessions.place(id, worker)
    session
  end

  defp draining do
    for worker <- Fleet.list_workers("dev"), worker.draining, do: worker.pod_name
  end
end
