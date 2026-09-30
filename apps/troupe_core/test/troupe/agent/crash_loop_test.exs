defmodule Troupe.Agent.CrashLoopTest do
  @moduledoc """
  A root agent that crashes every time it starts again (Decision 727). Its Node restarts
  it as often as it allows and the session does not start it again on top of that; its
  turn ends with `turn_ended`, `reason: agent_failed`, saying what it raised; and the
  session goes down, to come back dormant from its log.

  Both ways of crashing are here: a start that fails (`init/1` raises, so nothing after
  it is written) and a start that succeeds and then crashes on the turn it takes up
  again, which writes `agent_restarted` every time, the loop D37 saw.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Server, as: AgentServer
  alias Troupe.Session.Log

  # `Agent.Node`'s own limit: three starts again in five seconds.
  @max_restarts 3

  test "a root whose every start fails ends its turn saying why and takes the session down",
       context do
    %{sid: sid, path: path, session: ref} = settled_session(context)

    # Every start from here replays tool results that are not a list, and raises. Only the
    # agent folds them: a poison the session's summary read too would stop the session
    # by crashing that, and not by the agent.
    Log.append(sid, ["root"], :tool_results, %{"results" => "not a list"})
    Process.exit(Registry.agent_pid(sid, ["root"]), :kill)

    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, 5_000

    events = read(path)
    assert [%{"type" => "turn_ended", "data" => ended} | _] = Enum.reverse(events)
    assert %{"reason" => "agent_failed", "detail" => detail} = ended
    assert detail =~ "Protocol.UndefinedError"
    assert Enum.count(events, &(&1["data"]["reason"] == "agent_failed")) == 1

    # Nothing starts it again: the session stays down until something activates it. The
    # registry lets go of a name when it hears of the exit, which can be after the `:DOWN`
    # reached this test, so wait for that; a session started again would stay registered.
    unregistered(sid)
    refute Registry.whereis({:node, sid, ["root"]})
  end

  test "a root that crashes on the turn it takes up again is restarted as often as its Node allows",
       context do
    %{sid: sid, path: path, session: ref} = settled_session(context)

    # A goal the prompt cannot be built from, and a turn the model is owed: every start
    # again takes that turn up, and crashes building its request.
    Log.append(sid, ["root"], :goal_set, %{"text" => %{"not" => "text"}})
    Log.append(sid, ["root"], :user_input, %{"source" => "user", "text" => "carry on"})
    Process.exit(Registry.agent_pid(sid, ["root"]), :kill)

    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, 5_000

    events = read(path)
    assert Enum.count(events, &(&1["type"] == "agent_restarted")) == @max_restarts
    assert [%{"type" => "turn_ended", "data" => ended} | _] = Enum.reverse(events)
    assert %{"reason" => "agent_failed", "detail" => detail} = ended
    assert detail =~ "String.Chars"
  end

  test "a turn a crashing root ended is not taken up again when the session comes back",
       context do
    %{sid: sid, path: path, session: ref, fake: fake} = settled_session(context)

    Log.append(sid, ["root"], :goal_set, %{"text" => %{"not" => "text"}})
    Log.append(sid, ["root"], :user_input, %{"source" => "user", "text" => "carry on"})
    Process.exit(Registry.agent_pid(sid, ["root"]), :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, 5_000

    # Brought back as `resume_on_restart` would, which takes up a turn the model is owed:
    # this one ended as a failure, and taking it up is the loop again.
    {:ok, session} =
      Troupe.resume(sid,
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          auto_approve: true,
          model: "fake-model",
          state_dir: context.state_dir,
          resume_on_restart: true
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    # A call waits behind the action the agent came back with, so an answer is an agent
    # that did not crash taking the turn up; and nothing it would have written first is in.
    assert %{state: :idle} = AgentServer.snapshot(Registry.agent_pid(sid, ["root"]))

    since =
      path
      |> read()
      |> Enum.drop_while(&(&1["data"]["reason"] != "agent_failed"))
      |> Enum.map(& &1["type"])

    assert "agent_restarted" in since
    refute "instructions_loaded" in since
    refute "llm_request" in since
  end

  # A session that has answered one turn, subscribed and monitored.
  defp settled_session(context) do
    %{session: session, fake: fake} = start_session(context, steps: [{:text, "hello"}])
    sid = session.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "hi")
    await_state(sid, [:idle])

    Map.merge(context, %{
      sid: sid,
      fake: fake,
      path: Log.path(sid),
      session: Process.monitor(Registry.whereis({:session, sid}))
    })
  end

  defp read(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp unregistered(sid, timeout \\ 5_000),
    do: poll(fn -> is_nil(Registry.whereis({:session, sid})) end, now() + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      now() > deadline -> flunk("the session is still registered")
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
