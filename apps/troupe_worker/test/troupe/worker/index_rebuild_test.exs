defmodule Troupe.Worker.IndexRebuildTest do
  @moduledoc """
  Reconstructing the plane's session index from object storage alone.

  The question is what happens when PostgreSQL is gone. Every session's manifest is
  plaintext and every segment's epoch, last sequence number and head hash are in its key
  and its object metadata, so the index can be rebuilt without a key the plane is not
  allowed to have — and the rebuilt rows have to match the originals on every state,
  epoch and head hash.

  The other half is the fencing one: a pod presumed lost writes segments under an epoch
  the session has moved past, and the rebuilt index must contain no trace of them.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.{Erasure, Identity, Index, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions

  @moduletag timeout: 180_000

  setup context do
    context = requires_tier(context)

    unless Process.whereis(Repo) do
      flunk("no database for the plane; bring one up with `scripts/dev-up`")
    end

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, group} = Identity.upsert_group(%{external_id: context.team, display_name: context.team})
    {:ok, team} = Identity.enable_team(group, %{name: context.team})

    {:ok, user} =
      Identity.upsert_user(%{subject: "ada@example.test", email: "ada@example.test", display_name: "Ada"})

    # Erasure releases the pod slot the session was holding, which is the placement
    # actor's business.
    start_supervised!(Troupe.Plane.Singleton)

    Map.merge(context, %{team_row: team, user: user})
  end

  test "an emptied sessions table is reproduced from storage", context do
    original = run_a_real_session(context)

    # The catastrophe: the index is gone.
    PlaneSessions.delete(context.session_id)
    assert PlaneSessions.get(context.session_id) == nil

    assert {:ok, report} = Index.rebuild(store: context.store)
    assert report.rebuilt >= 1

    rebuilt = PlaneSessions.get(context.session_id)
    assert rebuilt

    # Every state, epoch and head hash, which is what the done item asks for.
    assert rebuilt.epoch == original.epoch
    assert rebuilt.head_hash == original.head_hash
    assert rebuilt.last_seq == original.last_seq
    assert rebuilt.state == "dormant"
    assert rebuilt.profile == original.profile
    assert rebuilt.owner_subject == "ada@example.test"
    assert rebuilt.team_id == context.team_row.id
    assert rebuilt.owner_id == context.user.id

    # And the anchors: without them nothing could later check storage against the index.
    anchors = PlaneSessions.anchors(context.session_id)
    assert anchors != []
    assert List.last(anchors).last_seq == original.last_seq
    assert List.last(anchors).head_hash == original.head_hash
  end

  test "a rebuild over a populated index overwrites rather than duplicates", context do
    original = run_a_real_session(context)

    assert {:ok, _} = Index.rebuild(store: context.store)
    assert {:ok, _} = Index.rebuild(store: context.store)

    rebuilt = PlaneSessions.get(context.session_id)
    assert rebuilt.epoch == original.epoch
    assert rebuilt.head_hash == original.head_hash

    # One row, one set of anchors: a rebuild is not an import.
    assert length(PlaneSessions.anchors(context.session_id)) == length(anchor_keys(context))
  end

  test "a stale epoch's segments are not in the rebuilt index", context do
    original = run_a_real_session(context)

    # A pod that was presumed lost seals a segment under the old epoch, covering ground
    # the session has already covered, and overwrites the manifest with its own idea of
    # where things got to.
    ghost_seq = original.last_seq + 50

    {:ok, _} =
      Storage.seal_segment(context.store, context.session_id, data_key(context), %{
        events: [%{"seq" => 1, "type" => "user_input", "data" => %{"text" => "from the ghost"}}],
        epoch: 1,
        first_seq: 1,
        last_seq: ghost_seq,
        head_hash: "sha256:ghost"
      })

    {:ok, _} =
      Storage.put_manifest(context.store, context.session_id, %{
        team: context.team,
        owner_subject: "ada@example.test",
        profile: "dev",
        epoch: 1,
        last_seq: ghost_seq,
        head_hash: "sha256:ghost"
      })

    PlaneSessions.delete(context.session_id)
    assert {:ok, _} = Index.rebuild(store: context.store)

    rebuilt = PlaneSessions.get(context.session_id)

    # The manifest said epoch 1 and a made-up head. The segments said otherwise, and the
    # segments are what a worker would replay.
    assert rebuilt.epoch == original.epoch
    assert rebuilt.head_hash == original.head_hash
    assert rebuilt.last_seq == original.last_seq
    refute rebuilt.head_hash == "sha256:ghost"

    refute Enum.any?(PlaneSessions.anchors(context.session_id), &(&1.head_hash == "sha256:ghost"))
  end

  test "an erased session is not resurrected by a stray object", context do
    _original = run_a_real_session(context)

    {:ok, _} =
      Erasure.erase(PlaneSessions.get(context.session_id),
        actor: "admin@example.test",
        reason: "retention"
      )

    # The tombstone stands even if something is left in the bucket.
    {:ok, _} = Storage.put_manifest(context.store, context.session_id, %{team: context.team, epoch: 9})

    assert {:ok, report} = Index.rebuild(store: context.store)
    assert report.skipped >= 1
    assert PlaneSessions.get(context.session_id).state == "erased"
    assert PlaneSessions.get(context.session_id).epoch != 9
  end

  # -- helpers ----------------------------------------------------------------

  # A session that really ran: real turns, real segments, real seals, then dormancy —
  # so what the rebuild reads is what a worker actually wrote.
  defp run_a_real_session(context) do
    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_id: context.user.id,
        owner_subject: "ada@example.test",
        team_id: context.team_row.id,
        profile: "dev",
        epoch: 2,
        state: "active"
      })

    assert {:ok, _} =
             activate(context,
               epoch: 2,
               owner_subject: "ada@example.test",
               profile: "dev",
               report: &record(context, &1)
             )
    run_turn(context.session_id, "hello")
    run_turn(context.session_id, "again")
    assert {:ok, sealed} = Sessions.dormant(context.session_id)

    {:ok, _} =
      PlaneSessions.dormant(context.session_id, %{
        last_seq: sealed.sealed_through,
        head_hash: sealed.head_hash
      })

    PlaneSessions.get(context.session_id)
  end

  defp record(context, report) do
    PlaneSessions.record_anchor(Map.put(report, "session_id", context.session_id), nil)
  end

  defp anchor_keys(context) do
    {:ok, segments} = Storage.list_segments(context.store, context.session_id)
    Storage.live_segments(segments)
  end
end
