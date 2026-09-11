defmodule Troupe.Worker.SealerTest do
  @moduledoc """
  What a lost pod costs.

  The sealer is the whole of the worker's durability promise: everything a session has
  done is in object storage except the events since the last seal, and the seal interval
  is the bound on that. These tests measure the bound rather than assuming it.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.KMS
  alias Troupe.Session.Log

  @moduletag timeout: 180_000

  test "a finished turn is sealed, and ephemerals are not in it", context do
    context = requires_tier(context)
    assert {:ok, _} = activate(context, report: reporter_to(self()))

    run_turn(context.session_id, "hello")

    report = await_sealed()
    assert report["session_id"] == context.session_id
    assert report["epoch"] == 1
    assert report["last_seq"] >= report["first_seq"]

    events = sealed_events(context)

    # Every sealed event carries a sequence number. An ephemeral one — a token delta, a
    # state change — has none, and a segment holding one would put undroppable weight
    # into the durable tier.
    assert Enum.all?(events, &is_integer(&1["seq"]))
    refute Enum.any?(events, &(&1["type"] in ["llm_delta", "agent_state", "progress"]))

    # The turn itself is in there: the request, the reply, and the message that started
    # it, all sealed by the time the agent came back to rest.
    assert Enum.any?(events, &(&1["type"] == "user_input"))
    assert Enum.any?(events, &(&1["type"] == "llm_response"))
    assert List.last(events)["seq"] == report["last_seq"]
  end

  test "the segment lands before the plane hears about it", context do
    context = requires_tier(context)

    test = self()

    reporter = fn report ->
      # Asked at the moment the report is made, not afterwards: a report that outran its
      # upload would let a rebuild claim history it cannot produce.
      send(test, {:sealed, report, ObjectStore.exists?(context.store, report["object_key"])})
    end

    assert {:ok, _} = activate(context, report: reporter)
    run_turn(context.session_id, "hello")

    assert_receive {:sealed, _report, true}, 20_000
    refute_received {:sealed, _, false}
  end

  test "a session that never finishes a turn is still sealed within the interval", context do
    context = requires_tier(context)

    # 300ms stands in for the production 60 seconds. What is being measured is that the
    # interval bounds the unsealed tail at all, not the particular number.
    assert {:ok, session} = activate(context, seal_interval_ms: 300, report: reporter_to(self()))

    # Let activation settle, then append an event that ends no turn at all. Nothing but
    # the interval can put it into storage.
    _ = await_sealed()

    {:ok, seq} = Log.append(context.session_id, ["root"], :progress_note, %{"n" => 1})

    eventually(fn ->
      match?({:ok, %{"last_seq" => last}} when last >= seq, Storage.get_manifest(context.store, context.session_id))
    end)

    assert Sealer.status(session.sealer).sealed_through >= seq
  end

  test "the manifest names the head, in plaintext, and says nothing about content", context do
    context = requires_tier(context)
    assert {:ok, _} = activate(context, report: reporter_to(self()))

    run_turn(context.session_id, "hello")
    report = await_sealed()

    {:ok, manifest} = Storage.get_manifest(context.store, context.session_id)

    assert manifest["session_id"] == context.session_id
    assert manifest["team"] == context.team
    assert manifest["last_seq"] == report["last_seq"]
    assert manifest["head_hash"] == report["head_hash"]
    assert manifest["key_path"] == KMS.path(context.team, context.session_id)

    # A manifest is readable without a key on purpose, which is exactly why it must
    # carry no session content. Nothing anyone said may appear in it.
    encoded = Jason.encode!(manifest)
    refute encoded =~ "hello"
    assert Map.keys(manifest) |> Enum.sort() == expected_manifest_keys()
  end

  test "the sealed head is the hash of the last event in the segment", context do
    context = requires_tier(context)
    assert {:ok, _} = activate(context, report: reporter_to(self()))

    run_turn(context.session_id, "hello")
    report = await_sealed()

    {:ok, events} =
      Storage.read_segment(context.store, context.session_id, data_key(context), report["object_key"])

    last = events |> List.last() |> Event.from_json()
    assert Event.hash(last) == report["head_hash"]
    assert last.seq == report["last_seq"]
  end

  test "a sealer that goes away takes its pending events with it, into storage", context do
    context = requires_tier(context)

    assert {:ok, session} = activate(context, seal_interval_ms: 600_000, report: reporter_to(self()))
    _ = await_sealed()

    Log.append(context.session_id, ["root"], :progress_note, %{"n" => 1})
    # Give the message time to reach the sealer's mailbox before stopping it.
    eventually(fn -> Sealer.status(session.sealer).pending > 0 end)

    GenServer.stop(session.sealer, :normal)

    assert await_sealed()["last_seq"] >= 1
  end

  defp expected_manifest_keys do
    ~w(epoch head_hash key_path last_seq latest_segment object_bytes owner_subject profile session_id team written_at)
  end
end
