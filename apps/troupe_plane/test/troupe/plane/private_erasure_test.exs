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

  alias Troupe.KMS
  alias Troupe.KMS.Policy
  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Erasure, FakePod, Harness, PersonAuth, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.Tombstone
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

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

  # Issue #348 is about private sessions. A team session's erasure is a pod's, and stays
  # exactly what it was: pushed to a healthy pod of its profile, or left for the next one
  # to enrol, and its key is never the plane's to touch.
  describe "a team session" do
    test "is still erased by a pod of its profile", %{root: root, port: port} do
      team_with_grant("engineering", "dev", name: "engineering")
      owner = person("owner-#{unique()}@example.test", ["engineering"])
      FakePod.enrol(port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => id}} =
               Harness.call("session.create", %{"profile" => "dev"}, as(owner))

      path = KMS.path("engineering", id)
      write_key(root, path)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(owner))

      assert_receive {:pushed, "session.erase", %{"session_id" => ^id, "team" => "engineering"}},
                     5_000

      assert Sessions.get(id).state == "erased"
      assert Erasure.tombstone_for(id).applied_by == ["troupe-w-dev-0"]
      # The pod destroys it; the plane does not.
      assert key_present?(root, path)
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

    test "with no healthy pod is erased and left for the next one to enrol", %{root: root} do
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
      assert key_present?(root, path)

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
