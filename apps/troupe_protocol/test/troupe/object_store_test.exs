defmodule Troupe.ObjectStoreTest do
  @moduledoc """
  S3, against a real one.

  Three behaviours are worth the round trip: that a listing is complete rather than a
  first page, that a versioned bucket keeps prior versions of an overwritten object, and
  that deleting a prefix removes every one of them. The last is what erasure rests on,
  and a double would have agreed with whatever this code believed.
  """

  use Troupe.ObjectStoreCase, async: false

  @moduletag timeout: 120_000

  test "an object written comes back exactly", context do
    %{store: store, prefix: prefix} = requires_store(context)
    body = :crypto.strong_rand_bytes(4096)

    assert {:ok, result} = ObjectStore.put(store, prefix <> "segments/1-1-40.seg", body)
    assert result.bytes == 4096

    assert {:ok, ^body} = ObjectStore.get(store, prefix <> "segments/1-1-40.seg")
    assert ObjectStore.exists?(store, prefix <> "segments/1-1-40.seg")
  end

  test "something that was never written is not found, rather than empty", context do
    %{store: store, prefix: prefix} = requires_store(context)

    assert {:error, :not_found} = ObjectStore.get(store, prefix <> "nothing")
    refute ObjectStore.exists?(store, prefix <> "nothing")
  end

  test "a listing is complete, not a first page", context do
    %{store: store, prefix: prefix} = requires_store(context)

    # Above S3's thousand-key page size, so the continuation token is exercised. A
    # session whose manifest is on page two is a session a rebuilt index would not have.
    for n <- 1..1_100 do
      {:ok, _} = ObjectStore.put(store, "#{prefix}blobs/#{n}", "x")
    end

    assert {:ok, keys} = ObjectStore.list(store, prefix <> "blobs/")
    assert length(keys) == 1_100
  end

  test "keys with awkward characters survive the round trip", context do
    %{store: store, prefix: prefix} = requires_store(context)
    key = prefix <> "workspace/a file with spaces & a +plus.tar"

    assert {:ok, _} = ObjectStore.put(store, key, "contents")
    assert {:ok, "contents"} = ObjectStore.get(store, key)

    # By name, not by count. This asserted `length(keys) == 1` and passed for months
    # while the listing said `a file with spaces &amp; a +plus.tar`: S3 escapes XML in
    # the values it returns, and an escaped key is a key that does not exist. Deleting
    # one that does not exist succeeds, so erasure reported this object gone on every
    # run and never touched it.
    assert {:ok, [^key]} = ObjectStore.list(store, prefix <> "workspace/")

    assert {:ok, [%{key: ^key}]} = ObjectStore.list_versions(store, prefix <> "workspace/")
    assert {:ok, 1} = ObjectStore.delete_prefix(store, prefix <> "workspace/")
    assert {:ok, []} = ObjectStore.list_versions(store, prefix <> "workspace/")
  end

  describe "versioning" do
    test "overwriting keeps the previous version", context do
      %{store: store, prefix: prefix} = requires_store(context)
      key = prefix <> "manifest.json"

      {:ok, first} = ObjectStore.put(store, key, "one")
      {:ok, second} = ObjectStore.put(store, key, "two")

      assert first.version_id
      assert second.version_id
      refute first.version_id == second.version_id

      assert {:ok, "two"} = ObjectStore.get(store, key)
      assert {:ok, "one"} = ObjectStore.get(store, key, version_id: first.version_id)
    end

    test "deleting a prefix removes every version, which is what erasure needs", context do
      %{store: store, prefix: prefix} = requires_store(context)
      key = prefix <> "segments/1-1-40.seg"

      {:ok, first} = ObjectStore.put(store, key, "ciphertext one")
      {:ok, _second} = ObjectStore.put(store, key, "ciphertext two")
      {:ok, _} = ObjectStore.put(store, prefix <> "snapshots/40.snap", "a snapshot")

      assert {:ok, versions} = ObjectStore.list_versions(store, prefix)
      assert length(versions) >= 3

      assert {:ok, removed} = ObjectStore.delete_prefix(store, prefix)
      assert removed >= 3

      # Not a delete marker over the top: the prior version is gone too. Erasure has to
      # leave nothing that decrypts, and in a versioned bucket an ordinary delete leaves
      # the content exactly where it was.
      assert {:error, :not_found} = ObjectStore.get(store, key)
      assert {:error, :not_found} = ObjectStore.get(store, key, version_id: first.version_id)
      assert {:ok, []} = ObjectStore.list(store, prefix)
      assert {:ok, []} = ObjectStore.list_versions(store, prefix)
    end

    # S3 lists at most a thousand versions at a time and says the rest is there with
    # `IsTruncated`. An erasure that read one page deleted a thousand versions of a long
    # session and left the others, which a key destroyed later is all that kept unread.
    test "deleting a prefix removes every version past the first thousand", context do
      %{store: store, prefix: prefix} = requires_store(context)

      # A few keys overwritten many times, which is how a long session's manifest piles
      # up versions and quicker to write than as many keys. Each key's versions in order,
      # so its oldest is known: the last of them a one-page listing reaches.
      oldest =
        1..6
        |> Task.async_stream(
          fn n ->
            key = "#{prefix}segments/#{n}.seg"
            for v <- 1..175, do: elem(ObjectStore.put(store, key, "ciphertext #{v}"), 1)
          end,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, [first | _]} -> first end)

      # A delete marker is a version too: one left behind still lists its key.
      :ok = ObjectStore.delete(store, hd(oldest).key)

      assert {:ok, removed} = ObjectStore.delete_prefix(store, prefix)

      for put <- oldest do
        assert {:error, :not_found} = ObjectStore.get(store, put.key, version_id: put.version_id)
      end

      assert {:ok, []} = ObjectStore.list_versions(store, prefix)
      assert {:ok, []} = ObjectStore.list(store, prefix)
      assert removed == 6 * 175 + 1
    end

    test "a listing of versions follows S3's markers from page to page", context do
      %{store: store, prefix: prefix} = requires_store(context)
      key = prefix <> "manifest.json"

      for n <- 1..12, do: {:ok, _} = ObjectStore.put(store, key, ~s({"last_seq":#{n}}))
      :ok = ObjectStore.delete(store, key)
      {:ok, _} = ObjectStore.put(store, prefix <> "snapshots/40.snap", "a snapshot")

      # Pages of five end inside one key's versions, so the next page has to start after
      # a version of a key and not just after the key.
      assert {:ok, versions} = ObjectStore.list_versions(store, prefix, page_size: 5)
      assert length(versions) == 14
      assert versions |> Enum.uniq() |> length() == 14

      assert {:ok, 14} = ObjectStore.delete_prefix(store, prefix, page_size: 5)
      assert {:ok, []} = ObjectStore.list_versions(store, prefix)
    end
  end
end
