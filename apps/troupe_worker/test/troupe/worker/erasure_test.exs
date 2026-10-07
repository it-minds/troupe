defmodule Troupe.Worker.ErasureTest do
  @moduledoc """
  Erasure, end to end, against a real key store and a real versioned bucket.

  The done item is a list of things that must be *gone*, and every one of them is
  checked against the thing itself rather than against this code's belief about it: the
  key is asked for at OpenBao, the objects are listed including prior versions, and the
  plane's row is read back.

  The order under test matters: the key is destroyed first, by the plane (Decision 811).
  Once it is gone nothing under the session's prefix decrypts — not the current objects,
  not the versions a versioned bucket keeps, not a copy in a backup — so the deletion the
  pod does after it is tidiness rather than the security property.

  Each side holds the credential an installation gives it, rendered by
  `Troupe.KMS.Policy`: the pod creates and reads its team's keys and may destroy none,
  and the plane may destroy any and read none. Under the development root token the pod
  could destroy a key, which is how a pod's erasure looked as if it worked while every
  installation refused it (issue #470).
  """

  use Troupe.Worker.SessionCase, async: false

  import Ecto.Query, only: [from: 2]
  import Troupe.ObjectStoreCase, only: [locked_bucket: 1, hold: 2, hold: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.KMS
  alias Troupe.KMS.Policy
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Erasure, Identity, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Plane.Sessions.{Session, Tombstone}
  alias Troupe.Sessions.Cipher
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.Session.Restore

  @moduletag timeout: 180_000

  @marker "the-thing-that-must-not-survive-4471"

  setup context do
    context = requires_tier(context)
    flunk_without_database()

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

    # The team is not decoration: the key lives at `troupe/teams/<team>/sessions/<id>`,
    # and the plane names it from the team.
    {:ok, group} = Identity.upsert_group(%{external_id: context.team, display_name: context.team})
    {:ok, team} = Identity.enable_team(group, %{name: context.team})

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: "ada@example.test",
        team_id: team.id,
        profile: "dev",
        epoch: 1,
        state: "active"
      })

    # The component credentials, for the length of each test. Registered after the
    # session case's own clean-up, so they are put back before it runs.
    kms = Application.get_env(:troupe_worker, :kms, [])
    transit = Application.get_env(:troupe_plane, :transit, [])
    pod = token_for(kms, [Policy.worker("secret", [context.team])])
    plane = token_for(kms, [Policy.plane("secret"), Policy.signing()])
    Application.put_env(:troupe_worker, :kms, Keyword.put(kms, :token, pod))
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :token, plane))

    on_exit(fn ->
      Application.put_env(:troupe_worker, :kms, kms)
      Application.put_env(:troupe_plane, :transit, transit)
    end)

    Map.merge(context, %{port: Listener.port(), root: kms, transit: transit, plane: plane})
  end

  test "destroys the key, the objects, and every prior version of them", context do
    link = attach_pod(context)

    # A session with real content in object storage, and more than one version of the
    # manifest so the versioned bucket has something to hide behind.
    assert {:ok, _} = activate(context, report: Link.reporter(link))
    run_turn(context.session_id, @marker)
    run_turn(context.session_id, "and again")
    assert {:ok, _} = Sessions.dormant(context.session_id)

    key = data_key(context)
    {:ok, before} = ObjectStore.list_versions(context.store, Storage.prefix(context.session_id))
    assert length(before) > 2
    assert decryptable?(context, key, before)

    session = PlaneSessions.get(context.session_id)
    assert {:ok, tombstone} = Erasure.erase(session, actor: "ada@example.test", reason: "requested")

    # 1. The key is gone from OpenBao, every version of it.
    assert {:error, :not_found} = KMS.adapter().fetch(context.team, context.session_id)
    refute KMS.adapter().exists?(context.team, context.session_id)
    assert tombstone.key_destroyed_at

    # 2. Nothing is left under the prefix, including prior versions.
    assert {:ok, []} = ObjectStore.list_versions(context.store, Storage.prefix(context.session_id))
    assert {:ok, []} = ObjectStore.list(context.store, Storage.prefix(context.session_id))

    # 3. The plane holds a tombstone and nothing else. The head hash survives on
    #    purpose: it is the last link of the audit chain, and erasing the proof that
    #    the session existed would look exactly like tampering it out of the index.
    assert tombstone.session_id == context.session_id
    assert tombstone.actor == "ada@example.test"
    assert tombstone.head_hash == session.head_hash
    assert PlaneSessions.get(context.session_id).state == "erased"

    dump = inspect(PlaneSessions.get(context.session_id)) <> inspect(Erasure.list())
    refute dump =~ @marker

    # 4. And the PVC holds nothing either.
    refute File.exists?(context.workspace)
  end

  # A pod session is erased only through the plane: its own token is refused
  # `session.erase` on the pod (`harness_auth_test.exs`), so this push is what has to reach
  # a session still running there and take the pod's copy along with the key and objects.
  test "reaches a session still running on the pod and takes the pod's copy", context do
    link = attach_pod(context)

    assert {:ok, _} = activate(context, report: Link.reporter(link))
    run_turn(context.session_id, @marker)

    # Sealed, so there are objects to delete and no upload still in flight.
    %{sealer: sealer} = Manager.status(Sessions.whereis(context.session_id))
    assert {:ok, _} = Sealer.seal_now(sealer)
    assert {:ok, [_ | _]} = ObjectStore.list(context.store, Storage.prefix(context.session_id))

    log_dir =
      Path.dirname(Restore.log_path(context.session_id, context.workspace, context.state_dir))

    assert File.exists?(context.workspace)
    assert File.exists?(log_dir)

    session = PlaneSessions.get(context.session_id)

    assert {:ok, tombstone} =
             Erasure.erase(session, actor: "ada@example.test", reason: "requested")

    # Carried out by this pod now, not left pending for the next one to enrol.
    assert tombstone.applied_by == ["troupe-w-dev-0"]

    # The pod's copy: the running tree, the workspace and the local log.
    assert Sessions.whereis(context.session_id) == nil
    refute File.exists?(context.workspace)
    refute File.exists?(log_dir)

    # And the rest of the erasure: the key, every version of every object, the plane's row.
    refute KMS.adapter().exists?(context.team, context.session_id)

    assert {:ok, []} =
             ObjectStore.list_versions(context.store, Storage.prefix(context.session_id))

    assert PlaneSessions.get(context.session_id).state == "erased"
  end

  test "a pod that was offline during the erasure applies it when it enrols", context do
    # The session's content exists, but no pod is attached: the objects cannot be deleted
    # when the erasure is asked for. The key can, and is.
    {:ok, key} = KMS.adapter().create(context.team, context.session_id)

    {:ok, _} =
      Storage.seal_segment(context.store, context.session_id, key, %{
        events: [%{"seq" => 1, "type" => "user_input", "data" => %{"text" => @marker}}],
        epoch: 1,
        first_seq: 1,
        last_seq: 1,
        head_hash: "sha256:whatever"
      })

    {:ok, _} = Storage.put_manifest(context.store, context.session_id, %{team: context.team, epoch: 1})

    session = PlaneSessions.get(context.session_id)
    assert {:ok, tombstone} = Erasure.erase(session, actor: "admin@example.test", reason: "retention")

    # The key went at once; the objects wait for a pod, unreadable meanwhile.
    refute KMS.adapter().exists?(context.team, context.session_id)
    assert PlaneSessions.get(context.session_id).state == "erased"
    assert tombstone.applied_by == []
    assert {:ok, [_ | _]} = ObjectStore.list(context.store, Storage.prefix(context.session_id))

    # The pod turns up. It applies the erasure before it serves anything.
    assert [%{"session_id" => pending}] = Erasure.pending_for("dev", "troupe-w-dev-0")
    assert pending == context.session_id

    _link = attach_pod(context)

    prefix = Storage.prefix(context.session_id)
    eventually(fn -> match?({:ok, []}, ObjectStore.list_versions(context.store, prefix)) end)

    # And the plane records that this pod has done it, so it is not asked again.
    eventually(fn -> Erasure.tombstone_for(context.session_id).applied_by != [] end)
    assert Erasure.pending_for("dev", "troupe-w-dev-0") == []
  end

  # D71: the pod's objects went through a delete whose answers were dropped, and it
  # answered the erasure carried out whatever the store said, so the plane recorded it and
  # no pod was ever told again.
  test "a pod the store refuses an object is not recorded, and its next enrolment finishes it",
       context do
    locked = locked_bucket(context.store)
    context = %{context | store: locked}
    prefix = Storage.prefix(context.session_id)
    _link = attach_pod(context)

    {:ok, key} = KMS.adapter().create(context.team, context.session_id)

    {:ok, _} =
      Storage.seal_segment(locked, context.session_id, key, %{
        events: [%{"seq" => 1, "type" => "user_input", "data" => %{"text" => @marker}}],
        epoch: 1,
        first_seq: 1,
        last_seq: 1,
        head_hash: "sha256:whatever"
      })

    {:ok, _} = Storage.put_manifest(locked, context.session_id, %{team: context.team, epoch: 1})
    {:ok, versions} = ObjectStore.list_versions(locked, prefix)
    held = Enum.find(versions, &String.contains?(&1.key, "/segments/"))
    :ok = hold(locked, held)

    session = PlaneSessions.get(context.session_id)

    assert {:ok, tombstone} =
             Erasure.erase(session, actor: "ada@example.test", reason: "requested")

    # The key went and the manifest with it; the held object did not, so this pod has not
    # carried the erasure out, and the plane goes on handing it out.
    refute KMS.adapter().exists?(context.team, context.session_id)
    assert {:ok, [%{version_id: version}]} = ObjectStore.list_versions(locked, prefix)
    assert version == held.version_id
    assert tombstone.applied_by == []
    assert [%{"session_id" => pending}] = Erasure.pending_for("dev", "troupe-w-dev-0")
    assert pending == context.session_id

    # Once the store lets it go, the pod's next enrolment finishes it and is recorded.
    :ok = hold(locked, held, false)
    stop_supervised!(Link)
    _link = attach_pod(context)

    eventually(fn ->
      Erasure.tombstone_for(context.session_id).applied_by == ["troupe-w-dev-0"]
    end)

    assert {:ok, []} = ObjectStore.list_versions(locked, prefix)
    assert Erasure.pending_for("dev", "troupe-w-dev-0") == []
  end

  # Issue #470: the pod logged a refused destroy and answered the erasure carried out, so
  # the plane recorded it and called the session erased with its key still there. The key
  # is the plane's now; refused, it is pending, and the pass that runs every five minutes
  # finishes it once the key manager answers.
  test "with the key manager refusing, the session is pending and the pod unrecorded, " <>
         "until a later pass destroys the key and records it",
       context do
    _link = attach_pod(context)
    {:ok, key} = KMS.adapter().create(context.team, context.session_id)

    {:ok, _} =
      Storage.seal_segment(context.store, context.session_id, key, %{
        events: [%{"seq" => 1, "type" => "user_input", "data" => %{"text" => @marker}}],
        epoch: 1,
        first_seq: 1,
        last_seq: 1,
        head_hash: "sha256:whatever"
      })

    session = PlaneSessions.get(context.session_id)

    without_delete(context, fn ->
      assert {:ok, tombstone} = Erasure.erase(session, actor: "ada@example.test")
      assert tombstone.applied_by == []
      assert is_nil(tombstone.key_destroyed_at)

      # Nothing the pass can do while the key manager still refuses.
      assert %{destroyed: 0, failed: 1} = Erasure.retry()
    end)

    assert KMS.adapter().exists?(context.team, context.session_id)
    assert PlaneSessions.get(context.session_id).state == "erasure_pending"
    assert Erasure.tombstone_for(context.session_id).applied_by == []

    # The pod was told at once all the same: nothing runs, and the objects are gone.
    prefix = Storage.prefix(context.session_id)
    assert {:ok, []} = ObjectStore.list_versions(context.store, prefix)

    # The key manager answers again.
    assert %{destroyed: 1, failed: 0} = Erasure.retry()

    refute KMS.adapter().exists?(context.team, context.session_id)
    assert PlaneSessions.get(context.session_id).state == "erased"
    assert Erasure.tombstone_for(context.session_id).applied_by == ["troupe-w-dev-0"]
    assert %{destroyed: 0, failed: 0} = Erasure.retry()
  end

  # The keys a pod was asked to destroy before 0.9, and could not: once, on upgrade, the
  # plane destroys them, and a refusal is tried again at the next pass.
  test "a key an earlier release left behind is destroyed once", context do
    {:ok, _} = KMS.adapter().create(context.team, context.session_id)
    old_erasure(context, applied_by: ["troupe-w-dev-0"])

    without_delete(context, fn -> assert %{destroyed: 0, failed: 1} = Erasure.retry() end)
    assert KMS.adapter().exists?(context.team, context.session_id)

    assert %{destroyed: 1, failed: 0} = Erasure.retry()
    refute KMS.adapter().exists?(context.team, context.session_id)

    tombstone = Erasure.tombstone_for(context.session_id)
    assert tombstone.key_destroyed_at
    assert tombstone.applied_by == ["troupe-w-dev-0"]
    assert PlaneSessions.get(context.session_id).state == "erased"

    # Once: the next pass has nothing to do, and a key already gone would count as done.
    assert %{destroyed: 0, failed: 0} = Erasure.retry()
  end

  # A disabled team's sessions keep their rows with no team (`on_delete: :nilify_all`);
  # the manifest still says where the key is.
  test "the key of a session whose team is gone is found from its manifest", context do
    manifest = %{team: context.team, epoch: 1}
    {:ok, _} = KMS.adapter().create(context.team, context.session_id)
    {:ok, _} = Storage.put_manifest(context.store, context.session_id, manifest)
    old_erasure(context, applied_by: [])

    Repo.update_all(from(s in Session, where: s.id == ^context.session_id), set: [team_id: nil])

    assert %{destroyed: 1, failed: 0} = Erasure.retry()
    refute KMS.adapter().exists?(context.team, context.session_id)
  end

  test "erasing twice is the same tombstone, not a second one", context do
    _link = attach_pod(context)
    {:ok, _} = KMS.adapter().create(context.team, context.session_id)
    {:ok, _} = Storage.put_manifest(context.store, context.session_id, %{team: context.team, epoch: 1})

    session = PlaneSessions.get(context.session_id)
    assert {:ok, first} = Erasure.erase(session, actor: "ada@example.test")
    assert {:ok, second} = Erasure.erase(context.session_id, actor: "someone-else@example.test")

    assert first.id == second.id
    assert second.actor == "ada@example.test"
    assert length(Erasure.list()) == 1
  end

  # -- helpers ----------------------------------------------------------------

  defp attach_pod(context) do
    Application.put_env(:troupe_worker, :session_defaults, store: context.store, state_dir: context.state_dir)
    on_exit(fn -> Application.delete_env(:troupe_worker, :session_defaults) end)

    link =
      start_supervised!(
        {Link,
         name: nil,
         host: "127.0.0.1",
         port: context.port,
         token: "dev-token",
         disk_path: context.base,
         claims: %{"pod_name" => "troupe-w-dev-0", "capacity" => 4, "disk_total_bytes" => 1_000_000}}
      )

    eventually(fn -> Link.connected?(link) end)
    link
  end

  # What an erasure before 0.9 left: the row erased, a tombstone with no key destroyed,
  # and the key still in the key manager.
  defp old_erasure(context, applied_by: applied_by) do
    {:ok, _} = PlaneSessions.put_state(context.session_id, "erased")

    Repo.insert!(%Tombstone{
      session_id: context.session_id,
      reason: "requested",
      actor: "ada@example.test",
      erased_at: DateTime.utc_now(),
      applied_by: applied_by
    })
  end

  # The plane with a credential that may sign and may not delete: the key manager refuses
  # it, as it refuses one that has stopped being honoured.
  defp without_delete(context, fun) do
    signing_only = token_for(context.root, [Policy.signing()])
    plane_token(context, signing_only)

    try do
      fun.()
    after
      plane_token(context, context.plane)
    end
  end

  defp plane_token(context, token),
    do: Application.put_env(:troupe_plane, :transit, Keyword.put(context.transit, :token, token))

  # A token carrying `policies` and nothing else, minted with the development root token
  # the suite is configured with.
  defp token_for(kms, policies) do
    names =
      for policy <- policies do
        name = "test-#{System.unique_integer([:positive])}"
        :ok = bao(kms, :post, "/v1/sys/policies/acl/#{name}", %{"policy" => policy})
        name
      end

    {:ok, %{"auth" => %{"client_token" => token}}} =
      bao(kms, :post, "/v1/auth/token/create", %{
        "policies" => names,
        "ttl" => "10m",
        "no_parent" => true
      })

    token
  end

  defp bao(kms, method, path, body) do
    case Req.request(
           method: method,
           url: kms[:address] <> path,
           headers: [{"x-vault-token", kms[:token]}],
           json: body,
           retry: false
         ) do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp decryptable?(context, key, versions) do
    Enum.any?(versions, fn version ->
      String.contains?(version.key, "/segments/") and
        match?({:ok, _}, read_version(context, key, version))
    end)
  end

  defp read_version(context, key, version) do
    with {:ok, body} <- ObjectStore.get(context.store, version.key, version_id: version.version_id) do
      Cipher.open(key, context.session_id, body)
    end
  end

  defp verify("dev-token") do
    {:ok, %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}

  defp flunk_without_database do
    unless Process.whereis(Repo) do
      flunk("no database for the plane; bring one up with `scripts/dev-up`")
    end
  end
end
