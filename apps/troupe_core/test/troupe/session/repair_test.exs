defmodule Troupe.Session.RepairTest do
  @moduledoc """
  A dormant session whose root's replay raises on an event in its log. Woken as any
  command wakes it, it fails, and says so once however often it is tried; woken past what
  it cannot read (`Troupe.repair/2`), the event is skipped by an appended `log_repaired`,
  the chain stays whole, and the session comes back.

  And a session whose supervisor restarts its `Log`: the root's next start is a start
  again, not its first, so a root that cannot start says why once.

  Not async: the session is woken through the daemon's index, as a client's command wakes
  it.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Protocol.Event.Actor
  alias Troupe.Session.Log

  setup context do
    write_file(context, ".troupe/config.yaml", """
    version: 1
    provider: fake
    model: fake-model
    auto_approve: true
    state_dir: #{Jason.encode!(context.state_dir)}
    """)

    :ok
  end

  @tag :capture_log
  test "a log its root cannot replay is woken past the event it cannot read", context do
    %{sid: sid, down: down} = settled(context)

    # Every start from here replays tool results that are not a list, and raises.
    {:ok, poison} = Log.append(sid, ["root"], :tool_results, %{"results" => "not a list"})
    Process.exit(Registry.agent_pid(sid, ["root"]), :kill)
    assert_receive {:DOWN, ^down, :process, _pid, _reason}, 5_000
    unregistered(sid)

    assert {:error, {:agent_failed, detail}} = Troupe.activate(sid)
    assert detail =~ "Protocol.UndefinedError"
    # Tried again, it fails again, and its log does not say so again.
    assert {:error, {:agent_failed, ^detail}} = Troupe.activate(sid)
    assert failures(context, sid) == 1

    assert {:ok, [^poison]} = Troupe.repair(sid, actor: Actor.user("alice", "Alice"))
    on_exit(fn -> Troupe.stop_session(sid) end)

    events = Log.read_session(sid, context.state_dir)
    assert :ok = Event.verify(events)
    assert [repaired] = Enum.filter(events, &(&1.type == "log_repaired"))
    assert %{"event" => ^poison, "by" => "Alice", "at" => at} = repaired.data
    assert at == Enum.find(events, &(&1.seq == poison)).ts
    assert repaired.agent == ["root"]
    assert %Actor{subject: "alice"} = repaired.actor

    # The event stays in the log, and every start from here skips it without being asked.
    assert Enum.any?(events, &(&1.seq == poison))
    :ok = Troupe.stop_session(sid)
    assert {:ok, _pid} = Troupe.activate(sid)
    assert {:ok, []} = Troupe.repair(sid)

    assert [_one] =
             sid |> Log.read_session(context.state_dir) |> Enum.filter(&(&1.type == "log_repaired"))
  end

  test "a repair of a session whose root reads its log skips nothing", context do
    %{sid: sid} = settled(context)
    :ok = Troupe.stop_session(sid)
    unregistered(sid)

    assert {:ok, []} = Troupe.repair(sid)
    on_exit(fn -> Troupe.stop_session(sid) end)
    refute Enum.any?(Log.read_session(sid, context.state_dir), &(&1.type == "log_repaired"))
  end

  test "a root started again after its log restarts is not on its first start", context do
    %{sid: sid} = settled(context)
    on_exit(fn -> Troupe.stop_session(sid) end)
    agent = Registry.agent_pid(sid, ["root"])

    log = Registry.whereis({:log, sid})
    Process.exit(log, :kill)

    eventually(fn ->
      pid = Registry.agent_pid(sid, ["root"])
      pid != nil and pid != agent and Process.alive?(pid)
    end)

    assert Log.restarts(sid, ["root"], 60_000) == 1
    refute Log.cold_start?(sid, ["root"])
  end

  @tag :capture_log
  test "a root that cannot start after its log restarts says so once", context do
    %{sid: sid, down: down} = settled(context)

    Log.append(sid, ["root"], :tool_results, %{"results" => "not a list"})
    Process.exit(Registry.whereis({:log, sid}), :kill)
    assert_receive {:DOWN, ^down, :process, _pid, _reason}, 10_000
    unregistered(sid)

    assert failures(context, sid) == 1
  end

  # A configured session that has answered one turn, subscribed and monitored.
  defp settled(context) do
    fake =
      start_supervised!(
        Supervisor.child_spec({Troupe.LLM.Fake, steps: [{:text, "hello"}], default: {:text, "done"}},
          id: {Troupe.LLM.Fake, make_ref()}
        )
      )

    {:ok, session} = Troupe.start_session(workspace: context.workspace, fake: fake)
    sid = session.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "hi")
    assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended"}}, 5_000

    %{sid: sid, down: Process.monitor(session.pid)}
  end

  defp failures(context, sid) do
    sid
    |> Log.read_session(context.state_dir)
    |> Enum.count(&(&1.type == "turn_ended" and &1.data["reason"] == "agent_failed"))
  end

  defp unregistered(sid),
    do: eventually(fn -> is_nil(Registry.whereis({:session, sid})) end, 5_000)
end
