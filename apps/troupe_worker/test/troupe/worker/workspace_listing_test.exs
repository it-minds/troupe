defmodule Troupe.Worker.WorkspaceListingTest do
  @moduledoc """
  A workspace comes back from what storage says it has, or not at all.

  The restore reads the events first and the tree second, and the tree's archive is found
  by listing the session's `workspace/` prefix. A listing that failed was read as "no
  archive": storage that went away between the two brought the session back with an empty
  working tree, or with whatever older tree this pod had cached, under a history that had
  moved past it — and the next archive would have sealed that over the real one. These pin
  that a failed listing fails the activation, named as #249 names an unreachable store, and
  that an empty listing is still an empty tree.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Sessions.Cipher
  alias Troupe.Worker.Cache
  alias Troupe.Worker.RecordingProxy
  alias Troupe.Worker.Session.{Restore, Workspace}

  @moduletag timeout: 120_000

  test "a listing that fails after the events were read fails the activation and leaves the cached tree alone",
       context do
    context = requires_tier(context)

    # This pod runs the session and puts it to sleep, which archives the tree to storage and
    # keeps the same sealed bytes in the pod's cache.
    assert {:ok, _} = activate(context)
    File.write!(Path.join(context.workspace, "notes.md"), "as this pod left it")
    assert {:ok, _} = Sessions.dormant(context.session_id)
    assert {:ok, cached_seq, cached} = Cache.get_workspace(context.session_id, context.state_dir)

    # Another pod runs it next and changes the tree, so storage now has a newer archive
    # than this pod's cache: the cache is stale, as a cache is allowed to be.
    elsewhere = Path.join(context.base, "pod-two")

    assert {:ok, _} =
             activate(context,
               workspace: Path.join(elsewhere, "workspace"),
               state_dir: Path.join(elsewhere, "state"),
               epoch: 2
             )

    File.write!(Path.join([elsewhere, "workspace", "notes.md"]), "as the other pod left it")
    assert {:ok, _} = Sessions.dormant(context.session_id)

    # Back on this pod, through a relay to the same store that drops the workspace listing
    # and nothing else: the events come back, and then storage does not answer.
    proxy =
      start_supervised!(
        {RecordingProxy,
         upstream: URI.parse(context.store.endpoint).port, drop: listing_of(context.session_id)}
      )

    endpoint = "http://127.0.0.1:#{RecordingProxy.port(proxy)}"

    assert {:error, {:object_store_unreachable, ^endpoint, _reason}} =
             activate(%{context | store: %{context.store | endpoint: endpoint}}, epoch: 3)

    assert Sessions.whereis(context.session_id) == nil

    # The events were read before the tree was asked for.
    captured = RecordingProxy.captured(proxy)
    assert captured =~ URI.encode_www_form(Storage.prefix(context.session_id) <> "segments/")
    assert captured =~ listing_of(context.session_id)

    # No tree was put back, neither the stale cached one nor an empty one, and the cache is
    # what it was.
    refute File.exists?(context.workspace)

    assert {:ok, ^cached_seq, ^cached} =
             Cache.get_workspace(context.session_id, context.state_dir)

    # And once storage answers again, the session comes back with the newer tree.
    assert {:ok, _} = activate(context, epoch: 4)
    assert File.read!(Path.join(context.workspace, "notes.md")) == "as the other pod left it"
  end

  describe "an empty listing is still an empty tree" do
    test "with nothing cached, the workspace is made and nothing is restored", context do
      context = requires_tier(context)
      root = Path.join(context.base, "fresh")

      assert {:ok, %{restored: false, seq: nil}} =
               Restore.workspace(restore_context(context), root)

      assert File.dir?(root)
      assert File.ls!(root) == []
    end

    test "with a cached archive, the cache is used as before", context do
      context = requires_tier(context)
      restore = restore_context(context)

      source = Path.join(context.base, "source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "kept.md"), "from the cache")
      {:ok, compressed, _plain} = Workspace.archive(source)
      sealed = Cipher.seal(restore.data_key, context.session_id, compressed)
      :ok = Cache.put_workspace(context.session_id, context.state_dir, 7, sealed)

      root = Path.join(context.base, "restored")

      assert {:ok, %{restored: true, seq: 7, source: :cache}} = Restore.workspace(restore, root)
      assert File.read!(Path.join(root, "kept.md")) == "from the cache"
    end
  end

  # The request line of the workspace listing, as `Troupe.ObjectStore.list/2` encodes it.
  defp listing_of(session_id) do
    "prefix=" <> URI.encode_www_form(Storage.prefix(session_id) <> "workspace/")
  end

  defp restore_context(context) do
    %Context{
      session_id: context.session_id,
      team: context.team,
      epoch: 1,
      data_key: :crypto.strong_rand_bytes(32),
      store: context.store,
      state_dir: context.state_dir
    }
  end
end
