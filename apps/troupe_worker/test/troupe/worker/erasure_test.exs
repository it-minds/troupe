defmodule Troupe.Worker.ErasureTest do
  @moduledoc """
  Erasure, end to end, against a real key store and a real versioned bucket.

  The done item is a list of things that must be *gone*, and every one of them is
  checked against the thing itself rather than against this code's belief about it: the
  key is asked for at OpenBao, the objects are listed including prior versions, and the
  plane's row is read back.

  The order under test matters: the key is destroyed first. Once it is gone nothing
  under the session's prefix decrypts — not the current objects, not the versions a
  versioned bucket keeps, not a copy in a backup — so the deletion that follows is
  tidiness rather than the security property.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.KMS
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Erasure, Identity, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Sessions.Cipher
  alias Troupe.Worker.Plane.Link

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

    # The team is not decoration: the key lives at
    # `troupe/teams/<team>/sessions/<id>`, so a pod told to erase without one would
    # delete the objects and leave the key.
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

    Map.put(context, :port, Listener.port())
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

  test "a pod that was offline during the erasure applies it when it enrols", context do
    # The session's content exists, but no pod is attached: this is the erasure that
    # cannot be carried out when it is asked for.
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

    # Nothing was destroyed: there was nobody to do it.
    assert tombstone.applied_by == []
    assert KMS.adapter().exists?(context.team, context.session_id)
    assert {:ok, [_ | _]} = ObjectStore.list(context.store, Storage.prefix(context.session_id))

    # The pod turns up. It applies the erasure before it serves anything.
    assert [%{"session_id" => pending}] = Erasure.pending_for("dev", "troupe-w-dev-0")
    assert pending == context.session_id

    _link = attach_pod(context)

    eventually(fn -> not KMS.adapter().exists?(context.team, context.session_id) end)
    assert {:ok, []} = ObjectStore.list_versions(context.store, Storage.prefix(context.session_id))

    # And the plane records that this pod has done it, so it is not asked again.
    eventually(fn -> Erasure.tombstone_for(context.session_id).applied_by != [] end)
    assert Erasure.pending_for("dev", "troupe-w-dev-0") == []
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
