defmodule Troupe.Worker.PvcLossTest do
  @moduledoc """
  Losing a pod's volume in the middle of a session.

  The promise is bounded, not absolute: everything sealed survives, and what is lost is
  the tail since the last seal — which the seal interval bounds at sixty seconds. This
  test destroys the volume the way Kubernetes would, with nothing warned and nothing
  flushed, and then brings the session back somewhere else from object storage alone.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Session.Log

  @moduletag timeout: 180_000

  test "everything sealed survives, and the session comes back elsewhere", context do
    context = requires_tier(context)

    assert {:ok, session} =
             activate(context,
               report: reporter_to(self()),
               seal_interval_ms: 600_000,
               archive_every_ms: 200
             )

    run_turn(context.session_id, "the part that must survive")
    File.write!(Path.join(context.workspace, "committed.md"), "sealed before the volume died")

    # Sealed by the turn boundary, and the plane has been told.
    sealed = await_sealed()
    assert sealed["last_seq"] > 0

    # And the workspace archived by its own interval, which is what bounds the *files* a
    # lost volume costs the way the seal interval bounds the history.
    eventually(fn -> archived?(context) end)

    # Now some events that are not sealed yet. In production this is at most sixty
    # seconds' worth; here the interval is long so the window is under the test's control
    # rather than the clock's.
    {:ok, lost_seq} = Log.append(context.session_id, ["root"], :progress_note, %{"n" => 1})
    File.write!(Path.join(context.workspace, "unsealed.md"), "written after the last seal")
    assert lost_seq > sealed["last_seq"]

    # The volume goes, and the pod with it. The sealer dies first and by `:kill`, so the
    # last-chance flush it would do for an orderly shutdown does not happen — a deleted
    # pod gets no such chance. Then the manager, then the actor tree, all without the
    # `session_dormant` an orderly stop would write.
    Process.exit(session.sealer, :kill)
    manager = Sessions.whereis(context.session_id)
    Process.exit(manager, :kill)
    eventually(fn -> Sessions.whereis(context.session_id) == nil end)
    Troupe.Sessions.stop_session(context.session_id)
    eventually(fn -> Troupe.agent_tree(context.session_id) == [] end)
    File.rm_rf!(context.base)

    refute File.exists?(context.workspace)

    # A different pod: a different volume, sharing nothing but object storage and the
    # key store.
    elsewhere = Path.join(System.tmp_dir!(), "troupe-pod-two-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(elsewhere) end)

    assert {:ok, _} =
             activate(context,
               workspace: Path.join(elsewhere, "workspace"),
               state_dir: Path.join(elsewhere, "state"),
               epoch: 2
             )

    events = Troupe.replay_from(context.session_id, 0)

    # Everything sealed is here, in order, and the chain over it holds.
    assert Enum.any?(events, &(&1.type == "user_input" and &1.data["text"] == "the part that must survive"))
    restored_head = Enum.find(events, &(&1.seq == sealed["last_seq"]))
    assert Event.hash(restored_head) == sealed["head_hash"]
    assert :ok = Event.verify(Enum.filter(events, &(&1.seq <= sealed["last_seq"])))

    # The workspace as it was at the last seal.
    assert File.read!(Path.join([elsewhere, "workspace", "committed.md"])) == "sealed before the volume died"

    # And what was lost is exactly the unsealed tail — not a byte of anything sealed.
    refute Enum.any?(events, &(&1.type == "progress_note"))
  end

  defp archived?(context) do
    case Troupe.ObjectStore.list(context.store, Storage.prefix(context.session_id) <> "workspace/") do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  test "the seal interval is what bounds the loss", context do
    context = requires_tier(context)

    # 300ms stands in for the production sixty seconds. What is measured is that an event
    # written with no turn boundary is in storage within one interval, which is the whole
    # of the bound.
    assert {:ok, _} = activate(context, seal_interval_ms: 300, report: reporter_to(self()))
    _ = await_sealed()

    {:ok, seq} = Log.append(context.session_id, ["root"], :progress_note, %{"n" => 1})
    written_at = System.monotonic_time(:millisecond)

    eventually(fn ->
      case Storage.get_manifest(context.store, context.session_id) do
        {:ok, %{"last_seq" => last}} -> last >= seq
        _ -> false
      end
    end)

    elapsed = System.monotonic_time(:millisecond) - written_at

    # Sixty seconds is the production interval; here the interval is 300ms and the event
    # is durable within a small multiple of it. The assertion is about the relationship,
    # not the number.
    assert elapsed < 3_000, "took #{elapsed}ms to seal, with a 300ms interval"
  end
end
