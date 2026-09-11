defmodule Troupe.Worker.ReaderTest do
  @moduledoc """
  Looking at a dormant session without waking it.

  The done item counts two things that must be zero: `Agent.Server` processes started
  and model calls made. Both are counted here against the real thing — the agent
  registry and the scripted model's own call count — because a reader that quietly
  started a tree would still serve the right history and would still be wrong.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Protocol.Event
  alias Troupe.Worker.Session.Reader

  @moduletag timeout: 180_000

  test "serves the full history with no agents and no model calls", context do
    {sealed, fake} = a_dormant_session(context)
    before = Fake.call_count(fake)

    assert {:ok, info} = Reader.open(context.session_id, reading(context))

    assert info.source == :storage
    assert info.last_seq == sealed.sealed_through
    assert info.head_hash == sealed.head_hash

    # The two numbers the done item is about.
    assert info.agents == 0
    assert Troupe.agent_tree(context.session_id) == []
    assert Fake.call_count(fake) == before

    # And the history really is all of it, in order, with the chain intact.
    events = Troupe.replay_from(context.session_id, 0)
    assert length(events) == sealed.sealed_through
    assert :ok = Event.verify(events)
    assert List.last(events).seq == sealed.sealed_through
    assert Event.hash(List.last(events)) == sealed.head_hash
    assert Enum.any?(events, &(&1.type == "user_input"))
  end

  test "does not activate the session", context do
    {_sealed, _fake} = a_dormant_session(context)

    assert {:ok, _} = Reader.open(context.session_id, reading(context))

    # No manager, so no epoch was consumed and no pod slot is held. This is the property
    # the whole dormancy design rests on.
    assert Sessions.whereis(context.session_id) == nil
    assert Sessions.active_count() == 0
  end

  test "exits once its last subscriber leaves", context do
    {_sealed, _fake} = a_dormant_session(context)
    assert {:ok, _} = Reader.open(context.session_id, reading(context))

    reader = Reader.whereis(context.session_id)
    assert is_pid(reader)

    watcher = spawn(fn -> receive do: (:stop -> :ok) end)
    assert :ok = Reader.follow(context.session_id, watcher)
    assert :ok = Reader.follow(context.session_id, self())

    # One leaves, the other stays: a reader serves everyone looking at the session.
    assert :ok = Reader.unfollow(context.session_id, self())
    Process.sleep(50)
    assert Process.alive?(reader)

    send(watcher, :stop)
    eventually(fn -> Reader.whereis(context.session_id) == nil end)
  end

  test "a session that is already running needs no reader", context do
    assert {:ok, _} = activate(context)
    run_turn(context.session_id, "hello")

    assert {:ok, info} = Reader.open(context.session_id, reading(context))
    assert info.source == :active
    assert info.agents > 0
    assert Reader.whereis(context.session_id) == nil
  end

  test "reading twice gives the same reader, not two", context do
    {_sealed, _fake} = a_dormant_session(context)

    assert {:ok, _} = Reader.open(context.session_id, reading(context))
    reader = Reader.whereis(context.session_id)

    assert {:ok, _} = Reader.open(context.session_id, reading(context))
    assert Reader.whereis(context.session_id) == reader
  end

  # -- helpers ----------------------------------------------------------------

  defp a_dormant_session(context) do
    fake = start_supervised!({Fake, steps: [], default: {:text, "done"}})
    assert {:ok, _} = activate(context, fake: fake)
    run_turn(context.session_id, "something worth remembering")
    assert {:ok, sealed} = Sessions.dormant(context.session_id)

    # Dormancy erased the local log, so what the reader finds it fetches from object
    # storage — which is the case worth testing.
    {sealed, fake}
  end

  defp reading(context) do
    [team: context.team, epoch: 1, store: context.store, state_dir: context.state_dir, workspace: context.workspace]
  end
end
