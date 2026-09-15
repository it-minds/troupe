defmodule Troupe.Plane.PrivateSessionsTest do
  @moduledoc """
  A session that belongs to a person rather than to a team.

  Every claim here is about what the plane does *not* get: no profile, no team, no pod,
  no bytes. What it does get is a row a second device can find, and a fence so that two
  devices waking on the same session produce one winner rather than two logs.

  The presigned URLs are signed against the real object store and then used, because a
  signature this suite constructs and checks against its own expectation proves nothing
  about whether MinIO would have accepted it.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Harness, Sessions}

  setup do
    ada = person("ada@example.test", [])
    bob = person("bob@example.test", [])
    %{ada: ada, bob: bob}
  end

  describe "registering" do
    test "creates a row with no team, no profile and no pod", %{ada: ada} do
      assert {:ok, json} =
               register(ada, %{
                 "session_id" => "p-1",
                 "device" => "ada-laptop",
                 "head_hash" => "sha256:aaa",
                 "last_seq" => 12,
                 "object_bytes" => 4096
               })

      assert json["kind"] == "private"
      assert json["device"] == "ada-laptop"
      assert json["epoch"] == 1
      assert json["last_seq"] == 12

      row = Sessions.get("p-1")
      assert row.team_id == nil
      assert row.profile == nil
      assert row.worker_id == nil
      assert row.owner_subject == ada.subject
    end

    test "is idempotent on the id, and a seal only moves forward", %{ada: ada} do
      {:ok, first} = register(ada, %{"session_id" => "p-2", "last_seq" => 10})

      # A daemon that sealed, lost its connection and retried must end up with one
      # session rather than two, or a refusal.
      {:ok, again} = register(ada, %{"session_id" => "p-2", "last_seq" => 20})
      assert again["epoch"] == first["epoch"]
      assert again["last_seq"] == 20

      # And a replay of an older seal is not a rewind.
      {:ok, replay} = register(ada, %{"session_id" => "p-2", "last_seq" => 15})
      assert replay["last_seq"] == 20
    end

    test "refuses somebody else's id, private or team", %{ada: ada, bob: bob} do
      {:ok, _} = register(ada, %{"session_id" => "p-3"})

      assert {:error, error} = register(bob, %{"session_id" => "p-3"})
      assert error.message == "forbidden"

      # A team session's id is refused too. The id space is shared, and `register` is the
      # one method where the client picks the id.
      team = team_with_grant("engineering", "dev", name: "engineering")

      {:ok, _} =
        Sessions.create(%{
          id: "t-1",
          owner_subject: ada.subject,
          team_id: team.id,
          profile: "dev"
        })

      assert {:error, refused} = register(ada, %{"session_id" => "t-1"})
      assert refused.message == "forbidden"
      assert Sessions.get("t-1").kind == "team"
    end

    test "the database refuses the shape even when nothing else does", %{ada: ada} do
      assert {:error, changeset} =
               Sessions.create(%{
                 id: "p-bad",
                 owner_subject: ada.subject,
                 kind: "private",
                 profile: "dev"
               })

      assert {"a private session has no profile", _} = changeset.errors[:profile]

      # The constraint, not the changeset. A row is what a placement reads, and this is
      # what stops a private session being handed a profile by some path nobody thought
      # about — including one written years from now.
      assert_raise Postgrex.Error, fn ->
        Repo.query!("""
        INSERT INTO sessions
          (id, owner_subject, kind, profile, visibility, state, epoch, pinned, last_seq,
           object_bytes, workspace_bytes, status, pending_approvals, cost_micros, usage_seq,
           inserted_at, updated_at)
        VALUES
          ('p-raw', 'ada', 'private', 'dev', 'private', 'active', 1, false, 0,
           0, 0, 'idle', 0, 0, 0, now(), now())
        """)
      end
    end
  end

  describe "the fence between two devices" do
    test "one claim wins and the loser is told on its next seal", %{ada: ada} do
      {:ok, _} = register(ada, %{"session_id" => "p-4", "device" => "laptop", "last_seq" => 5})

      # Both devices read epoch 1. Both try to take it.
      assert {:ok, won} =
               register(ada, %{
                 "session_id" => "p-4",
                 "claim" => true,
                 "epoch" => 1,
                 "device" => "desktop"
               })

      assert won["epoch"] == 2
      assert won["device"] == "desktop"

      assert {:error, lost} =
               register(ada, %{
                 "session_id" => "p-4",
                 "claim" => true,
                 "epoch" => 1,
                 "device" => "laptop"
               })

      assert lost.message == "stale_version"

      # The loser learns it lost when it seals, which is the moment it matters: nothing
      # reaches a laptop that is not asking.
      assert {:error, stale} =
               register(ada, %{"session_id" => "p-4", "epoch" => 1, "last_seq" => 9})

      assert stale.message == "stale_version"
      assert Sessions.get("p-4").last_seq == 5

      # And the winner goes on sealing.
      assert {:ok, sealed} = register(ada, %{"session_id" => "p-4", "epoch" => 2, "last_seq" => 9})
      assert sealed["last_seq"] == 9
    end

    test "a claim on somebody else's session is refused, not fenced", %{ada: ada, bob: bob} do
      {:ok, _} = register(ada, %{"session_id" => "p-5"})

      assert {:error, error} =
               register(bob, %{"session_id" => "p-5", "claim" => true, "epoch" => 1})

      assert error.message == "forbidden"
      assert Sessions.get("p-5").epoch == 1
    end
  end

  describe "listing" do
    test "separates a person's own sessions from their team's", %{ada: ada} do
      team = team_with_grant("engineering", "dev", name: "engineering")

      {:ok, _} =
        Sessions.create(%{
          id: "t-2",
          owner_subject: ada.subject,
          owner_id: ada.id,
          team_id: team.id,
          profile: "dev"
        })

      {:ok, _} = register(ada, %{"session_id" => "p-6"})

      assert {:ok, %{"sessions" => all}} = Harness.call("sessions.list", %{}, as(ada))
      assert Enum.sort(Enum.map(all, & &1["id"])) == ["p-6", "t-2"]

      assert {:ok, %{"sessions" => [only]}} =
               Harness.call("sessions.list", %{"kind" => "private"}, as(ada))

      assert only["id"] == "p-6"
      assert only["profile"] == nil
    end

    test "a private session is nobody else's, team or not", %{ada: ada, bob: bob} do
      {:ok, _} = register(ada, %{"session_id" => "p-7"})

      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, as(bob))
      assert {:error, error} = Harness.call("session.get", %{"session_id" => "p-7"}, as(bob))
      assert error.message == "not_found"
    end
  end

  describe "presigned URLs" do
    test "a signed PUT and GET round-trips through the real store", %{ada: ada} do
      {:ok, _} = register(ada, %{"session_id" => "p-8"})
      key = "sessions/p-8/segments/00000001.seg"

      assert {:ok, %{"urls" => puts, "expires_in" => 300}} =
               presign(ada, "p-8", "put", [key])

      # The bytes never touch the plane: a laptop with a URL and no credential.
      ciphertext = :crypto.strong_rand_bytes(64)
      assert %{status: status} = Req.put!(puts[key], body: ciphertext, decode_body: false)
      assert status in 200..299

      assert {:ok, %{"urls" => gets}} = presign(ada, "p-8", "get", [key])
      assert %{status: 200, body: ^ciphertext} = Req.get!(gets[key], decode_body: false)
    end

    test "signs only keys under this session's prefix", %{ada: ada, bob: bob} do
      {:ok, _} = register(ada, %{"session_id" => "p-9"})
      {:ok, _} = register(bob, %{"session_id" => "p-10"})

      for key <- ["sessions/p-10/manifest.json", "sessions/p-9/../p-10/x", "manifest.json"] do
        assert {:error, error} = presign(ada, "p-9", "put", [key])
        assert error.message == "invalid_params", "signed #{key}"
      end
    end

    test "refuses a session that is not the caller's", %{ada: ada, bob: bob} do
      {:ok, _} = register(ada, %{"session_id" => "p-11"})

      assert {:error, error} = presign(bob, "p-11", "get", ["sessions/p-11/manifest.json"])
      assert error.message == "forbidden"
    end

    test "a signature stops working when it expires", %{ada: ada} do
      {:ok, _} = register(ada, %{"session_id" => "p-12"})
      key = "sessions/p-12/manifest.json"
      store = ObjectStore.from_env()
      {:ok, _} = ObjectStore.put(store, key, "{}")

      # A lifetime is not a suggestion, and this is the half of the design that makes a
      # URL copied into a log harmless an hour later. Signed as of an hour ago with the
      # same five minutes, which is arithmetic the store does rather than we do.
      an_hour_ago =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      url = ObjectStore.presign(store, :get, key, ttl: 300, now: an_hour_ago)
      assert %{status: 403} = Req.get!(url, decode_body: false)

      assert %{status: 200} =
               store |> ObjectStore.presign(:get, key, ttl: 300) |> Req.get!(decode_body: false)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp register(user, params), do: Harness.call("session.register", params, as(user))

  defp presign(user, session_id, method, keys) do
    Harness.call(
      "session.presign",
      %{"session_id" => session_id, "method" => method, "keys" => keys},
      as(user)
    )
  end

  defp as(user), do: %{user: user, platform_admin?: false}
end
