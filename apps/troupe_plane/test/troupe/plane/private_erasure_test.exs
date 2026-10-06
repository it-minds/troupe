defmodule Troupe.Plane.PrivateErasureTest do
  @moduledoc """
  Erasing a session that belongs to a person (issue #348, Decision 756).

  A private session has no profile, so the pod a team session's erasure is handed to
  does not exist. The plane destroys the key itself, at once, with the `delete` on key
  metadata its policy has for exactly this; the objects go when the owner's daemon next
  connects and says it has stopped; and until the key is gone the session says the
  erasure is pending rather than that it is done.

  Against the development OpenBao and MinIO, and with a plane credential carrying the
  plane's policy and nothing more: "the plane can destroy a person's key and read none" is
  a statement about OpenBao's answer, not about our code.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog
  import Troupe.ObjectStoreCase, only: [locked_bucket: 1, hold: 2, hold: 3]

  alias Troupe.KMS
  alias Troupe.KMS.Policy
  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Erasure, FakePod, Harness, PersonAuth, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.Tombstone
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  # How long a daemon waits for the plane's answer (`Troupe.Gateway.Plane`).
  @daemon_waits_ms 15_000

  setup_all do
    cond do
      not PersonAuth.reachable?() ->
        IO.puts(
          :stderr,
          "\nSKIPPED: no OpenBao (#{PersonAuth.address()}); bring one up with `scripts/dev-up`.\n"
        )

        {:ok, skip: "no OpenBao"}

      not match?({:ok, _}, ObjectStore.list(ObjectStore.from_env(), "reachability-probe/")) ->
        IO.puts(:stderr, "\nSKIPPED: no object storage; bring it up with `scripts/dev-up`.\n")
        {:ok, skip: "no object storage"}

      true ->
        :ok
    end
  end

  setup context do
    requires_services(context)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})
    start_supervised!({Task.Supervisor, name: Erasure.Tasks})

    # The plane's credential, for the length of each test: the plane's policy and the
    # signing policy, which is what an installation gives the `troupe-plane` role. The
    # root token stays in hand for what an operator or a daemon would write.
    transit = Application.get_env(:troupe_plane, :transit, [])
    root = transit[:token]
    plane = token_for(root, [Policy.plane("secret"), Policy.signing()])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :token, plane))
    on_exit(fn -> Application.put_env(:troupe_plane, :transit, transit) end)

    # Per run, not per test: the database is rolled back and the key manager is not.
    ada = person("ada-#{unique()}@example.test", [])
    bob = person("bob-#{unique()}@example.test", [])

    %{ada: ada, bob: bob, root: root, plane: plane, transit: transit, port: Listener.port()}
  end

  describe "a private session" do
    test "has its key destroyed in the key manager at once", %{ada: ada, root: root} do
      # Under her name at the key manager, which is not her subject once she has been
      # moved to another claim (Decision 755). The plane looks the name up; it does not
      # take the subject for it.
      ada = moved(ada, "ada-name-#{unique()}")
      id = registered(ada, "ada-laptop")
      path = KMS.path({:person, User.kms_name(ada)}, id)
      write_key(root, path)
      assert key_present?(root, path)

      assert {:ok, answer} = Harness.call("session.erase", %{"session_id" => id}, as(ada))
      assert answer["erased"] == true
      assert answer["state"] == "erased"

      refute key_present?(root, path)
      assert Sessions.get(id).state == "erased"
      assert Erasure.tombstone_for(id)
    end

    test "reads as pending until its key is destroyed, and erasing again finishes it",
         %{ada: ada, root: root} = context do
      id = registered(ada, "ada-laptop")
      path = KMS.path({:person, User.kms_name(ada)}, id)
      write_key(root, path)

      # A plane whose credential may sign and may not delete: the key manager refuses,
      # which is the same answer an unreachable one gives as far as the erasure goes.
      without_delete(context, fn ->
        assert {:ok, answer} = Harness.call("session.erase", %{"session_id" => id}, as(ada))
        assert answer["erased"] == false
        assert answer["state"] == "erasure_pending"

        assert key_present?(root, path)
        assert Sessions.get(id).state == "erasure_pending"

        # Listed as what it is, so the person can see it is not done.
        assert {:ok, %{"sessions" => [listed]}} = Harness.call("sessions.list", %{}, as(ada))
        assert listed["id"] == id
        assert listed["state"] == "erasure_pending"

        # Not handed to her daemon yet: the key goes first, and the objects after it.
        assert {:ok, %{"erasures" => []}} = erasures(ada, "ada-laptop")
        assert key_present?(root, path)

        # And nothing seals, keys or signs for it in the meantime.
        assert_erased_refusals(ada, id)
      end)

      assert {:ok, again} = Harness.call("session.erase", %{"session_id" => id}, as(ada))
      assert again["erased"] == true
      assert again["state"] == "erased"
      refute key_present?(root, path)
      assert Sessions.get(id).state == "erased"
    end

    test "reads the same to an administrator who erases it", %{ada: ada, root: root} = context do
      admin = %{subject: "root@example.test", role: :platform_admin, teams: []}
      id = registered(ada, "ada-laptop")
      path = KMS.path({:person, User.kms_name(ada)}, id)
      write_key(root, path)

      without_delete(context, fn ->
        assert {:ok, %{state: "erasure_pending"}} = Admin.session_erase(admin, id)
      end)

      assert key_present?(root, path)
      assert {:ok, %{state: "erased"}} = Admin.session_erase(admin, id)
      refute key_present?(root, path)
    end

    test "a key left behind is destroyed when its owner's daemon next connects",
         %{ada: ada, root: root} = context do
      id = registered(ada, "ada-laptop")
      path = KMS.path({:person, User.kms_name(ada)}, id)
      write_key(root, path)

      without_delete(context, fn ->
        assert {:ok, %{"state" => "erasure_pending"}} =
                 Harness.call("session.erase", %{"session_id" => id}, as(ada))
      end)

      # The plane is on this path anyway, and it is the moment the person is back.
      assert {:ok, %{"erasures" => [told]}} = erasures(ada, "ada-laptop")
      assert told["session_id"] == id
      refute key_present?(root, path)
      assert Sessions.get(id).state == "erased"
    end

    # Before Decision 756 the erasure wrote its tombstone and then failed, leaving the row
    # active and the key in place, and every later erase answered that it was done.
    test "one an older plane tombstoned and left is finished too", %{ada: ada, root: root} do
      id = registered(ada, "ada-laptop")
      path = KMS.path({:person, User.kms_name(ada)}, id)
      write_key(root, path)

      Repo.insert!(%Tombstone{
        session_id: id,
        reason: "requested",
        actor: ada.subject,
        erased_at: DateTime.utc_now()
      })

      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-laptop")
      refute key_present?(root, path)
      assert Sessions.get(id).state == "erased"
    end

    test "has its objects deleted when its owner's daemon next connects, which says so once",
         %{ada: ada, root: root} do
      id = registered(ada, "ada-laptop")
      write_key(root, KMS.path({:person, User.kms_name(ada)}, id))

      # What a daemon's earlier seals left: segments, and a manifest written twice, so a
      # prior version is there too. The bucket is versioned and every version has to go.
      store = ObjectStore.from_env()
      {:ok, _} = ObjectStore.put(store, "sessions/#{id}/segments/e1-00000001-00000002.seg", "x")
      {:ok, _} = ObjectStore.put(store, "sessions/#{id}/manifest.json", ~s({"last_seq":1}))
      {:ok, _} = ObjectStore.put(store, "sessions/#{id}/manifest.json", ~s({"last_seq":2}))
      assert length(versions(id)) == 3

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      # Not yet. The daemon is the only writer, and until it says it has stopped a
      # deletion could be followed by the segment it was uploading.
      assert length(versions(id)) == 3

      assert {:ok, %{"erasures" => [told]}} = erasures(ada, "ada-laptop")
      assert told["session_id"] == id
      assert told["erased_at"]

      assert {:ok, done} = erased(ada, id, "ada-laptop")
      assert done["session_id"] == id
      assert versions(id) == []

      # Once: the same device is not told again.
      assert {:ok, %{"erasures" => []}} = erasures(ada, "ada-laptop")
      assert "ada-laptop" in Erasure.tombstone_for(id).applied_by

      # Another of her devices may hold a copy too, and is told until it says so.
      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-desktop")
      assert {:ok, _} = erased(ada, id, "ada-desktop")
      assert {:ok, %{"erasures" => []}} = erasures(ada, "ada-desktop")
    end

    # S3 lists a thousand versions at a time, and the deletion read the first page only:
    # a session sealed for long enough kept the rest of its ciphertext.
    test "has every version of its objects deleted, past the first thousand",
         %{ada: ada, root: root} do
      id = registered(ada, "ada-laptop")
      write_key(root, KMS.path({:person, User.kms_name(ada)}, id))

      store = ObjectStore.from_env()
      names = ~w(manifest.json segments/e1-a.seg segments/e1-b.seg snapshots/1.snap)

      names
      |> Task.async_stream(
        fn name ->
          for n <- 1..260, do: {:ok, _} = ObjectStore.put(store, "sessions/#{id}/#{name}", "#{n}")
        end,
        timeout: 60_000
      )
      |> Stream.run()

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-laptop")
      assert {:ok, done} = erased(ada, id, "ada-laptop")

      assert {:ok, []} = ObjectStore.list(store, "sessions/#{id}/")
      assert versions(id) == []
      assert done["objects_deleted"] == 4 * 260
      assert done["deleting"] == false
    end

    # D71: one `DELETE` a version, inside the call. A thousand took seconds, so twenty
    # thousand outlasted the fifteen seconds a daemon waits for its answer
    # (`Troupe.Gateway.Plane`), which then said the plane had not been told.
    @tag timeout: 600_000
    test "has twenty thousand versions deleted without its daemon's call timing out",
         %{ada: ada, root: root} do
      id = registered(ada, "ada-laptop")
      write_key(root, KMS.path({:person, User.kms_name(ada)}, id))
      written = write_versions(ObjectStore.from_env(), id, 400, 50)
      assert length(versions(id)) == written

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-laptop")

      {took, answer} = :timer.tc(fn -> erased(ada, id, "ada-laptop") end, :millisecond)
      assert {:ok, %{"session_id" => ^id}} = answer
      assert took < @daemon_waits_ms, "answered after #{took} ms"

      # Gone, and the device recorded, whether within the call or after it.
      eventually(fn -> versions(id) == [] and acknowledged?(id, "ada-laptop") end)
      assert {:ok, %{"erasures" => []}} = erasures(ada, "ada-laptop")
    end

    # D71: each version's answer was dropped, so a version the store refused was counted
    # as deleted, the device recorded, and nothing ever tried again.
    test "keeps telling its daemon while the store refuses a version, until it is gone",
         %{ada: ada, root: root} do
      locked = plane_store_locked()
      id = registered(ada, "ada-laptop")
      write_key(root, KMS.path({:person, User.kms_name(ada)}, id))

      {:ok, held} = ObjectStore.put(locked, "sessions/#{id}/segments/e1-1-2.seg", "x")
      {:ok, _} = ObjectStore.put(locked, "sessions/#{id}/manifest.json", ~s({"last_seq":2}))
      :ok = hold(locked, held)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-laptop")

      assert {:error, refused} = erased(ada, id, "ada-laptop")
      assert refused.message == "unavailable"
      assert %{objects_deleted: 1, objects_left: 1} = refused.data

      # Not recorded, so told again, and the rest of it went meanwhile.
      refute acknowledged?(id, "ada-laptop")
      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-laptop")

      assert {:ok, [%{version_id: version}]} =
               ObjectStore.list_versions(locked, "sessions/#{id}/")

      assert version == held.version_id

      # Once the store lets it go, the next acknowledgement finishes it.
      :ok = hold(locked, held, false)
      assert {:ok, done} = erased(ada, id, "ada-laptop")
      assert %{"objects_deleted" => 1, "deleting" => false} = done
      assert {:ok, []} = ObjectStore.list_versions(locked, "sessions/#{id}/")
      assert {:ok, %{"erasures" => []}} = erasures(ada, "ada-laptop")
    end

    # Decision 804: past what the call can wait, the answer says the deletion is still
    # going, and the device is recorded when it has gone, or told again when it has not.
    test "answers before a deletion that outlasts the call, and records the device after it",
         %{ada: ada, root: root} do
      Application.put_env(:troupe_plane, :erasure_answer_ms, 0)
      on_exit(fn -> Application.delete_env(:troupe_plane, :erasure_answer_ms) end)

      locked = plane_store_locked()
      id = registered(ada, "ada-laptop")
      write_key(root, KMS.path({:person, User.kms_name(ada)}, id))
      write_versions(locked, id, 10, 3)
      {:ok, held} = ObjectStore.put(locked, "sessions/#{id}/manifest.json", ~s({"last_seq":9}))
      :ok = hold(locked, held)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      assert {:ok, answer} = erased(ada, id, "ada-laptop")
      assert answer["deleting"] == true
      refute Map.has_key?(answer, "objects_deleted")

      # The task's deletion is refused one version, so the device is told again.
      eventually(fn -> Task.Supervisor.children(Erasure.Tasks) == [] end)

      assert {:ok, [%{version_id: version}]} =
               ObjectStore.list_versions(locked, "sessions/#{id}/")

      assert version == held.version_id
      refute acknowledged?(id, "ada-laptop")
      assert {:ok, %{"erasures" => [%{"session_id" => ^id}]}} = erasures(ada, "ada-laptop")

      :ok = hold(locked, held, false)
      assert {:ok, %{"deleting" => true}} = erased(ada, id, "ada-laptop")
      eventually(fn -> acknowledged?(id, "ada-laptop") end)
      assert {:ok, []} = ObjectStore.list_versions(locked, "sessions/#{id}/")
      assert {:ok, %{"erasures" => []}} = erasures(ada, "ada-laptop")
    end

    test "is not sealed, keyed or signed for once erased", %{ada: ada, root: root} do
      id = registered(ada, "ada-laptop")
      path = KMS.path({:person, User.kms_name(ada)}, id)
      write_key(root, path)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      # A daemon still running it would otherwise go on sealing into the erased prefix
      # and, asking for an assertion, make a fresh key where the old one was.
      assert_erased_refusals(ada, id)
      refute key_present?(root, path)
    end

    test "has its objects deleted only once erased, and only for its owner",
         %{ada: ada, bob: bob} do
      live = registered(ada, "ada-laptop")
      store = ObjectStore.from_env()
      {:ok, _} = ObjectStore.put(store, "sessions/#{live}/manifest.json", "{}")

      # Saying a session is erased does not erase it.
      assert {:error, refused} = erased(ada, live, "ada-laptop")
      assert refused.message == "not_found"
      assert length(versions(live)) == 1

      gone = registered(ada, "ada-laptop")
      {:ok, _} = ObjectStore.put(store, "sessions/#{gone}/manifest.json", "{}")

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => gone}, as(ada))

      # Nor is it somebody else's to say.
      assert {:error, forbidden} = erased(bob, gone, "bob-laptop")
      assert forbidden.message == "not_found"
      assert {:ok, %{"erasures" => []}} = erasures(bob, "bob-laptop")
      assert length(versions(gone)) == 1
    end
  end

  # A team session's key is the plane's to destroy too (Decision 811): a pod's credential
  # may destroy none, so a pod asked to left every one behind (issue #470). The pod is
  # still told at once, for its copy and the objects, and recorded once the key is gone.
  describe "a team session" do
    test "has its key destroyed by the plane and its objects by a pod of its profile",
         %{root: root, port: port} do
      team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])
      FakePod.enrol(port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => id}} =
               Harness.call("session.create", %{"profile" => "dev"}, as(owner))

      path = KMS.path("engineering", id)
      write_key(root, path)

      assert {:ok, %{"erased" => true, "state" => "erased"}} =
               Harness.call("session.erase", %{"session_id" => id}, as(owner))

      assert_receive {:pushed, "session.erase", %{"session_id" => ^id}}, 5_000

      refute key_present?(root, path)
      assert Sessions.get(id).state == "erased"
      assert Erasure.tombstone_for(id).applied_by == ["troupe-w-dev-0"]
      assert Erasure.tombstone_for(id).key_destroyed_at
    end

    test "whose key the key manager refuses is pending and refused everything but a look " <>
           "and another erase, until a later pass destroys it",
         %{root: root, port: port} = context do
      team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])
      bea = person("bea-#{unique()}@example.test", [])
      FakePod.enrol(port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => id}} =
               Harness.call("session.create", %{"profile" => "dev"}, as(owner))

      path = KMS.path("engineering", id)
      write_key(root, path)

      # A link made before the erasure, which outlives it.
      share = %{"session_id" => id, "role" => "observe"}
      assert {:ok, %{"secret" => secret}} = Harness.call("session.share", share, as(owner))

      without_delete(context, fn ->
        assert {:ok, %{"erased" => false, "state" => "erasure_pending"}} =
                 Harness.call("session.erase", %{"session_id" => id}, as(owner))

        # The pod is told at once all the same, and not recorded while the key is there.
        assert_receive {:pushed, "session.erase", %{"session_id" => ^id}}, 5_000
        assert Erasure.tombstone_for(id).applied_by == []
        assert key_present?(root, path)
        assert Sessions.get(id).state == "erasure_pending"

        # Listed and looked at as what it is, and erasing again tries again.
        assert {:ok, %{"sessions" => listed}} = Harness.call("sessions.list", %{}, as(owner))
        assert %{"state" => "erasure_pending"} = Enum.find(listed, &(&1["id"] == id))

        assert {:ok, %{"state" => "erasure_pending"}} =
                 Harness.call("session.get", %{"session_id" => id}, as(owner))

        assert {:ok, %{"state" => "erasure_pending"}} =
                 Harness.call("session.erase", %{"session_id" => id}, as(owner))

        # Nothing reads it, wakes it, mints for it, copies it or links to it.
        for {method, params, user} <- [
              {"session.open", %{"session_id" => id}, owner},
              {"session.open", %{"session_id" => id, "mode" => "activate"}, owner},
              {"token.mint", %{"session_id" => id}, owner},
              {"session.fork", %{"session_id" => id}, owner},
              {"session.spawn", %{"parent" => id, "prompt" => "go on"}, owner},
              {"session.share", %{"session_id" => id, "role" => "observe"}, owner},
              {"session.redeem", %{"secret" => secret}, bea}
            ] do
          assert {:error, error} = Harness.call(method, params, as(user)), "#{method} answered"
          assert error.message == "not_found", "#{method}: #{inspect(error)}"
          assert error.data.reason == "erased"
        end

        # A pod's late report of a dormancy does not bring it back.
        assert {:error, :parked} = Sessions.dormant(id)
        assert Sessions.get(id).state == "erasure_pending"

        # Another pod enrolling drops its copy, and is not recorded for it yet either.
        assert [%{"session_id" => ^id}] = Erasure.pending_for("dev", "troupe-w-dev-1")
        Erasure.applied(id, "troupe-w-dev-1")
        assert Erasure.tombstone_for(id).applied_by == []
      end)

      # The key manager answers again.
      assert %{destroyed: 1, failed: 0} = Erasure.retry()

      refute key_present?(root, path)
      assert Sessions.get(id).state == "erased"
      assert_receive {:pushed, "session.erase", %{"session_id" => ^id}}, 5_000
      assert Erasure.tombstone_for(id).applied_by == ["troupe-w-dev-0"]

      assert {:error, %{message: "not_found"}} =
               Harness.call("session.redeem", %{"secret" => secret}, as(bea))
    end

    test "whose pod could not delete every object is erased, and the pod told again",
         %{root: root, port: port} do
      team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])

      FakePod.enrol(port, "dev-token", "troupe-w-dev-0",
        refuse: %{
          "session.erase" => %{
            "code" => -32_010,
            "message" => "unavailable",
            "data" => %{"reason" => "held", "objects_deleted" => 1, "objects_left" => 1}
          }
        }
      )

      assert {:ok, %{"session_id" => id}} =
               Harness.call("session.create", %{"profile" => "dev"}, as(owner))

      path = KMS.path("engineering", id)
      write_key(root, path)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(owner))

      refute key_present?(root, path)
      assert Erasure.tombstone_for(id).applied_by == []
      assert [%{"session_id" => ^id}] = Erasure.pending_for("dev", "troupe-w-dev-0")
    end

    # The upgrade: a team session an earlier release erased still has its key, since the pod
    # it asked could not destroy one, and the pass that runs as the plane starts destroys it.
    test "left with its key by an earlier release has it destroyed by the pass the plane " <>
           "starts with",
         %{root: root} do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])
      id = SessionId.generate()

      {:ok, _} =
        Sessions.create(%{
          id: id,
          owner_id: owner.id,
          owner_subject: owner.subject,
          team_id: team.id,
          profile: "dev",
          state: "erased"
        })

      Repo.insert!(%Tombstone{
        session_id: id,
        reason: "requested",
        actor: owner.subject,
        erased_at: DateTime.utc_now(),
        applied_by: ["troupe-w-dev-0"]
      })

      path = KMS.path("engineering", id)
      write_key(root, path)

      log =
        capture_log(fn ->
          assert {:ok, pass} = Erasure.Retry.ensure()
          # Its first pass is the first thing in its mailbox.
          :sys.get_state(pass, 30_000)
        end)

      refute key_present?(root, path)
      assert Erasure.tombstone_for(id).key_destroyed_at
      assert Erasure.tombstone_for(id).applied_by == ["troupe-w-dev-0"]
      assert log =~ "erasure pass destroyed 1 session key(s)"
    end

    test "is never handed to a person's daemon", %{port: port} do
      team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])
      FakePod.enrol(port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => id}} =
               Harness.call("session.create", %{"profile" => "dev"}, as(owner))

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(owner))

      assert {:ok, %{"erasures" => []}} = erasures(owner, "owner-laptop")
      assert {:error, refused} = erased(owner, id, "owner-laptop")
      assert refused.message == "not_found"
    end

    test "with no healthy pod has its key destroyed and is left for the next one to enrol",
         %{root: root} do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])
      id = SessionId.generate()

      {:ok, _} =
        Sessions.create(%{
          id: id,
          owner_id: owner.id,
          owner_subject: owner.subject,
          team_id: team.id,
          profile: "dev",
          state: "dormant"
        })

      path = KMS.path("engineering", id)
      write_key(root, path)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(owner))

      assert Sessions.get(id).state == "erased"
      refute key_present?(root, path)

      assert [%{"session_id" => ^id, "team" => "engineering"}] =
               Erasure.pending_for("dev", "troupe-w-dev-0")
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp requires_services(%{skip: reason}), do: flunk("skipped: #{reason}")
  defp requires_services(_context), do: :ok

  defp unique, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp as(user), do: %{user: user, platform_admin?: false}

  defp registered(user, device) do
    id = SessionId.generate()

    assert {:ok, _row} =
             Harness.call("session.register", %{"session_id" => id, "device" => device}, as(user))

    id
  end

  defp erasures(user, device),
    do: Harness.call("session.erasures", %{"device" => device}, as(user))

  defp erased(user, id, device),
    do: Harness.call("session.erased", %{"session_id" => id, "device" => device}, as(user))

  defp assert_erased_refusals(user, id) do
    key = "sessions/#{id}/segments/e1-00000003-00000003.seg"

    for {method, params} <- [
          {"session.register", %{"session_id" => id, "epoch" => 1, "last_seq" => 9}},
          {"session.register", %{"session_id" => id, "claim" => true, "epoch" => 1}},
          {"session.assertion", %{"session_id" => id}},
          {"session.presign", %{"session_id" => id, "method" => "put", "keys" => [key]}},
          {"session.objects", %{"session_id" => id}}
        ] do
      assert {:error, error} = Harness.call(method, params, as(user)), "#{method} answered"
      assert error.message == "not_found", "#{method}: #{inspect(error)}"
      assert error.data.reason == "erased"
    end
  end

  # Moved to another claim after being first known, as a re-key leaves a person: the name
  # at the key manager is no longer the subject.
  defp moved(user, name) do
    user |> Ecto.Changeset.change(kms_name: name) |> Repo.update!()
  end

  defp without_delete(%{transit: transit, root: root, plane: plane}, fun) do
    signing_only = token_for(root, [Policy.signing()])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :token, signing_only))

    try do
      fun.()
    after
      Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :token, plane))
    end
  end

  defp versions(id) do
    {:ok, versions} = ObjectStore.list_versions(ObjectStore.from_env(), "sessions/#{id}/")
    versions
  end

  # `objects` keys written `times` times each, as a long session's segments and manifest
  # pile up versions; many keys rather than many versions of one, which is quicker.
  defp write_versions(store, id, objects, times) do
    1..objects
    |> Task.async_stream(
      fn n ->
        for v <- 1..times,
            do: {:ok, _} = ObjectStore.put(store, "sessions/#{id}/segments/e1-#{n}.seg", "#{v}")
      end,
      max_concurrency: 32,
      timeout: :infinity
    )
    |> Stream.run()

    objects * times
  end

  # A bucket of the test's own with object lock on, which the plane's erasures go to for
  # the length of the test: how a real store is made to refuse a delete.
  defp plane_store_locked do
    locked = locked_bucket(ObjectStore.from_env())
    config = Application.get_env(:troupe_protocol, :object_store, [])

    Application.put_env(
      :troupe_protocol,
      :object_store,
      Keyword.put(config, :bucket, locked.bucket)
    )

    on_exit(fn -> Application.put_env(:troupe_protocol, :object_store, config) end)
    locked
  end

  defp acknowledged?(id, device), do: device in Erasure.tombstone_for(id).applied_by

  defp eventually(check, tries \\ 300) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  # -- the key manager, as an operator and a daemon reach it ------------------

  defp write_key(root, path) do
    :ok =
      bao(root, :post, "/v1/secret/data/#{encode(path)}", %{
        "data" => %{"key" => Base.encode64(:crypto.strong_rand_bytes(32))}
      })
  end

  defp key_present?(root, path) do
    case Req.request(
           method: :get,
           url: PersonAuth.address() <> "/v1/secret/metadata/#{encode(path)}",
           headers: [{"x-vault-token", root}],
           retry: false
         ) do
      {:ok, %{status: 200}} -> true
      {:ok, %{status: 404}} -> false
    end
  end

  defp token_for(root, policies) do
    names =
      for policy <- policies do
        name = "test-#{unique()}"
        :ok = bao(root, :post, "/v1/sys/policies/acl/#{name}", %{"policy" => policy})
        name
      end

    {:ok, %{status: 200, body: body}} =
      Req.request(
        method: :post,
        url: PersonAuth.address() <> "/v1/auth/token/create",
        headers: [{"x-vault-token", root}],
        json: %{"policies" => names, "ttl" => "10m", "no_parent" => true},
        decode_body: true,
        retry: false
      )

    get_in(body, ["auth", "client_token"])
  end

  defp bao(root, method, path, body) do
    case Req.request(
           method: method,
           url: PersonAuth.address() <> path,
           headers: [{"x-vault-token", root}],
           json: body,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
