defmodule Troupe.Worker.StorageTest do
  @moduledoc """
  A session in object storage, against a real one.

  The layout is an interface: a rebuild reads it without a key, erasure deletes it by
  prefix, and fencing depends on the epoch being part of a segment's name. All three are
  checked here, and the last one — that a stale epoch's segments are not part of a
  session's history — is the mechanism that keeps a pod presumed lost from rewriting one.
  """

  use Troupe.Worker.ObjectStoreCase, async: false

  alias Troupe.Worker.Storage

  @moduletag timeout: 120_000

  setup context do
    if store = context[:store] do
      session_id = "s-#{System.unique_integer([:positive])}"
      on_exit(fn -> Storage.erase(store, session_id) end)

      %{store: store, session_id: session_id, key: :crypto.strong_rand_bytes(32)}
    else
      :ok
    end
  end

  defp session(context) do
    context = requires_store(context)
    {context.store, context.session_id, context.key}
  end

  defp events(from, to) do
    for seq <- from..to do
      %{"seq" => seq, "type" => "user_input", "ts" => "2026-01-01T00:00:00Z", "data" => %{"text" => "line #{seq}"}}
    end
  end

  describe "segments" do
    test "a sealed segment reads back as the events that went in", context do
      {store, session_id, key} = session(context)

      assert {:ok, segment} =
               Storage.seal_segment(store, session_id, key, %{events: events(1, 40), epoch: 1})

      assert segment.first_seq == 1
      assert segment.last_seq == 40
      assert segment.key =~ "segments/"

      assert {:ok, read} = Storage.read_segment(store, session_id, key, segment.key)
      assert length(read) == 40
      assert Enum.map(read, & &1["seq"]) == Enum.to_list(1..40)
    end

    test "a segment is compressed, because a log repeats itself", context do
      {store, session_id, key} = session(context)

      plain = events(1, 500) |> Enum.map_join("\n", &Jason.encode!/1)
      {:ok, segment} = Storage.seal_segment(store, session_id, key, %{events: events(1, 500), epoch: 1})

      assert segment.bytes < byte_size(plain) / 2,
             "a 500-event segment compressed to #{segment.bytes} from #{byte_size(plain)}"
    end

    test "nothing readable is in the object itself", context do
      {store, session_id, key} = session(context)

      marker = "CANARY-NOT-IN-OBJECT-STORAGE"
      event = %{"seq" => 1, "type" => "user_input", "data" => %{"text" => marker}}

      {:ok, segment} = Storage.seal_segment(store, session_id, key, %{events: [event], epoch: 1})
      {:ok, raw} = ObjectStore.get(store, segment.key)

      refute raw =~ marker
      assert {:ok, [read]} = Storage.read_segment(store, session_id, key, segment.key)
      assert read["data"]["text"] == marker
    end

    test "segments sort by epoch then sequence, whatever the numbers", context do
      {store, session_id, key} = session(context)

      for {epoch, first, last} <- [{1, 1, 9}, {1, 10, 120}, {2, 121, 130}] do
        {:ok, _} =
          Storage.seal_segment(store, session_id, key, %{
            events: events(first, last),
            epoch: epoch,
            first_seq: first,
            last_seq: last
          })
      end

      assert {:ok, segments} = Storage.list_segments(store, session_id)

      # Lexicographic on a zero-padded key, which is what an object store gives back —
      # unpadded, `10` sorts before `9` and a replay reads the tail first.
      assert Enum.map(segments, &{&1.epoch, &1.first_seq}) == [{1, 1}, {1, 10}, {2, 121}]
    end
  end

  describe "fencing" do
    test "a stale epoch's segments are not part of the history" do
      # A pod presumed lost keeps writing under epoch 1 while the session runs on
      # epoch 2 somewhere else. Following the contiguous chain is what leaves its
      # segments out.
      segments = [
        %Storage.Segment{epoch: 1, first_seq: 1, last_seq: 40},
        %Storage.Segment{epoch: 2, first_seq: 41, last_seq: 80},
        # Written by the lost pod after the session had already moved on.
        %Storage.Segment{epoch: 1, first_seq: 41, last_seq: 55},
        %Storage.Segment{epoch: 2, first_seq: 81, last_seq: 90}
      ]

      live = Storage.live_segments(segments)

      assert Enum.map(live, &{&1.epoch, &1.first_seq, &1.last_seq}) ==
               [{1, 1, 40}, {2, 41, 80}, {2, 81, 90}]
    end

    test "a gap ends the chain rather than skipping it" do
      # A missing segment is a missing segment. Carrying on past it would hand a replay
      # a history with a hole in it and no way to know.
      segments = [
        %Storage.Segment{epoch: 1, first_seq: 1, last_seq: 40},
        %Storage.Segment{epoch: 1, first_seq: 60, last_seq: 80}
      ]

      assert [%{last_seq: 40}] = Storage.live_segments(segments)
    end
  end

  describe "snapshots, workspaces and blobs" do
    test "a snapshot round trips and the newest is findable", context do
      {store, session_id, key} = session(context)

      {:ok, _} = Storage.put_snapshot(store, session_id, key, 40, %{"todos" => ["one"]})
      {:ok, _} = Storage.put_snapshot(store, session_id, key, 500, %{"todos" => ["two"]})

      assert Storage.latest_snapshot_seq(store, session_id) == 500
      assert {:ok, %{"todos" => ["two"]}} = Storage.get_snapshot(store, session_id, key, 500)
    end

    test "a workspace archive round trips", context do
      {store, session_id, key} = session(context)
      archive = :crypto.strong_rand_bytes(50_000)

      {:ok, _} = Storage.put_workspace(store, session_id, key, 40, archive)
      assert {:ok, ^archive} = Storage.get_workspace(store, session_id, key, 40)
    end

    test "a blob is addressed by its own content", context do
      {store, session_id, key} = session(context)
      content = String.duplicate("a very long tool result\n", 1000)

      assert {:ok, digest} = Storage.put_blob(store, session_id, key, content)
      assert digest =~ ~r/^sha256:[0-9a-f]{64}$/
      assert {:ok, ^content} = Storage.get_blob(store, session_id, key, digest)

      # The same content twice is the same blob, within this session.
      assert {:ok, ^digest} = Storage.put_blob(store, session_id, key, content)
    end

    test "a blob does not exist under another session's prefix", context do
      {store, session_id, key} = session(context)
      {:ok, digest} = Storage.put_blob(store, session_id, key, "one session's output")

      # Deduplication within a session and never across one: another session's storage
      # must not be a probe for this one's content.
      other = "s-#{System.unique_integer([:positive])}"
      assert {:error, :not_found} = Storage.get_blob(store, other, key, digest)
    end
  end

  describe "the manifest" do
    test "is readable without a key, and carries no content", context do
      {store, session_id, key} = session(context)

      {:ok, _} =
        Storage.put_manifest(store, session_id, %{
          team: "dev",
          owner_subject: "idp|alice",
          profile: "dev",
          epoch: 2,
          last_seq: 90,
          head_hash: "sha256:abc",
          key_path: Troupe.KMS.path("dev", session_id),
          object_bytes: 4096
        })

      # No key is passed. A rebuild has to enumerate sessions from storage alone.
      assert {:ok, manifest} = Storage.get_manifest(store, session_id)
      assert manifest["session_id"] == session_id
      assert manifest["team"] == "dev"
      assert manifest["epoch"] == 2
      assert manifest["key_path"] =~ "troupe/teams/dev/sessions/"

      # Ids and sizes, and nothing that was said.
      refute Map.has_key?(manifest, "events")
      refute Map.has_key?(manifest, "conversation")

      assert {:ok, sessions} = Storage.list_sessions(store)
      assert session_id in sessions

      _ = key
    end
  end

  test "erasing removes everything, every version", context do
    {store, session_id, key} = session(context)

    {:ok, segment} = Storage.seal_segment(store, session_id, key, %{events: events(1, 10), epoch: 1})
    {:ok, _} = Storage.put_snapshot(store, session_id, key, 10, %{"x" => 1})
    {:ok, digest} = Storage.put_blob(store, session_id, key, "a result")
    {:ok, _} = Storage.put_manifest(store, session_id, %{team: "dev"})
    # A second version of the manifest, as an update would leave behind.
    {:ok, _} = Storage.put_manifest(store, session_id, %{team: "dev", epoch: 2})

    assert {:ok, removed} = Storage.erase(store, session_id)
    assert removed >= 5

    assert {:error, :not_found} = ObjectStore.get(store, segment.key)
    assert {:error, :not_found} = Storage.get_manifest(store, session_id)
    assert {:error, :not_found} = Storage.get_blob(store, session_id, key, digest)
    assert {:ok, []} = ObjectStore.list_versions(store, Storage.prefix(session_id))
  end
end
