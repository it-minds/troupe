defmodule Troupe.Worker.SnapshotTest do
  @moduledoc """
  Snapshots are cache, and are treated like cache.

  The done item asks for one behaviour: a corrupted or version-mismatched snapshot falls
  back to a full replay *with the same result*. That "same result" is the part worth
  testing, because a fallback that produced something slightly different would be a
  fallback nobody could trust — and the whole reason a snapshot may be discarded freely
  is that discarding it costs time and nothing else.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Session.Summary
  alias Troupe.Sessions.Snapshot
  alias Troupe.Worker.Session.{Context, Restore}

  @moduletag timeout: 180_000

  setup context do
    context = requires_tier(context)

    # A session with enough history that a snapshot is worth having, sealed across
    # several segments so the tail really is a tail. Its own snapshotting is off, because
    # each test writes the snapshot it wants to reason about.
    assert {:ok, _} = activate(context, snapshot_every: 1_000_000, report: reporter_to(self()))

    run_turn(context.session_id, "the first thing")
    run_turn(context.session_id, "the second thing")
    run_turn(context.session_id, "the third thing")
    _ = await_sealed()

    assert Storage.latest_snapshot_seq(context.store, context.session_id) == nil

    {:ok, worker_context} =
      Context.open(context.session_id,
        team: context.team,
        epoch: 1,
        store: context.store,
        state_dir: context.state_dir
      )

    Map.put(context, :context, worker_context)
  end

  test "a usable snapshot is used, and says so", context do
    write_snapshot(context, %{"tokens" => 1_234, "todo" => "from the snapshot"}, 2)

    assert {:ok, result} = Restore.projection(context.context)

    assert result.from == :snapshot
    assert result.from_seq == 2
    assert result.fold["todo"] == "from the snapshot"
  end

  test "a snapshot from another build is discarded, and the replay agrees", context do
    # What the truth is, with no snapshot at all.
    assert {:ok, full} = Restore.projection(context.context)
    assert {:replayed, :none} = full.from

    write_snapshot(context, %{"tokens" => 999_999}, 2, code_version: "0.0.1-from-last-year")

    assert {:ok, fallen_back} = Restore.projection(context.context)

    assert fallen_back.from == {:replayed, :wrong_code_version}
    assert fallen_back.from_seq == 0
    assert fallen_back.fold == full.fold
    refute fallen_back.fold["tokens"] == 999_999
  end

  test "a snapshot in an older format is discarded, and the replay agrees", context do
    assert {:ok, full} = Restore.projection(context.context)

    stored = %{"format" => 0, "code_version" => Snapshot.code_version(), "seq" => 2, "fold" => %{"tokens" => 7}}
    put_raw(context, stored, 2)

    assert {:ok, fallen_back} = Restore.projection(context.context)

    assert fallen_back.from == {:replayed, :wrong_format}
    assert fallen_back.fold == full.fold
  end

  test "a snapshot that will not decode is discarded, and the replay agrees", context do
    assert {:ok, full} = Restore.projection(context.context)

    put_raw(context, %{"this" => "is not a snapshot"}, 2)

    assert {:ok, fallen_back} = Restore.projection(context.context)

    assert fallen_back.from == {:replayed, :malformed}
    assert fallen_back.fold == full.fold
  end

  test "a snapshot whose bytes are damaged is discarded, and the replay agrees", context do
    assert {:ok, full} = Restore.projection(context.context)

    # Not a valid ciphertext at all: this is a corrupted object, not a stale one.
    key = Storage.snapshot_key(context.session_id, 2)
    {:ok, _} = ObjectStore.put(context.store, key, :crypto.strong_rand_bytes(512))

    assert {:ok, fallen_back} = Restore.projection(context.context)

    assert match?({:replayed, _reason}, fallen_back.from)
    assert fallen_back.fold == full.fold
  end

  test "the fold from a snapshot plus its tail equals the fold from everything", context do
    assert {:ok, full} = Restore.projection(context.context)

    # A snapshot taken from the real fold up to seq 2, which is what the sealer writes.
    partial = fold_through(context, 2)
    write_snapshot(context, partial, 2)

    assert {:ok, from_snapshot} = Restore.projection(context.context)

    assert from_snapshot.from == :snapshot
    assert from_snapshot.fold == full.fold
  end

  # -- helpers ----------------------------------------------------------------

  defp write_snapshot(context, fold, seq, opts \\ []) do
    put_raw(context, Snapshot.wrap(fold, seq, opts), seq)
  end

  defp put_raw(context, stored, seq) do
    {:ok, _} =
      Storage.put_snapshot(context.store, context.session_id, data_key(context), seq, stored)
  end

  # The fold the sealer would have taken at `seq`, computed the way the sealer computes
  # it: over the events up to that point and no further.
  defp fold_through(context, seq) do
    context
    |> sealed_events()
    |> Enum.map(&Event.from_json/1)
    |> Enum.filter(&(&1.seq <= seq))
    |> Enum.reduce(Summary.empty(), &Summary.fold(&2, &1))
  end
end
