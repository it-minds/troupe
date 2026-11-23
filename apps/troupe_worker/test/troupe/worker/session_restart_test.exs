defmodule Troupe.Worker.SessionRestartTest do
  @moduledoc """
  A running session raised to its channel's current bundle version by its owner (#1177):
  the plane pushes `session.restart`, and the pod starts the session's tree again in place,
  over the log and the workspace it has, with the new pin. Never inside a turn: a busy tree
  keeps the raise and takes it when its root next comes to rest. The move is the log's
  `config_upgraded`, with why and who; a tree that does not come back sends the session to
  sleep, so its next wake applies the raise. Needs the session tier (OpenBao and MinIO), as
  every `SessionCase` suite does.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Session.Log
  alias Troupe.Sessions.Sealer
  alias Troupe.Worker.Plane.Commands
  alias Troupe.Worker.Session.Manager
  alias Troupe.Worker.Sessions

  @moduletag timeout: 120_000

  @v12 %{
    version: 12,
    hash: nil,
    channel: "stable",
    dir: nil,
    upgraded_from: nil,
    entitlements: nil,
    agent_rule: nil,
    repository_overrides: false,
    profile: "fixing"
  }

  setup context do
    context = requires_tier(context)
    Map.put(context, :sid, context.session_id)
  end

  test "an idle session's tree starts again on the raised version, keeping its workspace, its log and every subscription",
       context do
    sid = context.sid
    {:ok, _} = activate(context, bundle: @v12, report: reporter_to(self()), fake: fake([]))
    File.write!(Path.join(context.workspace, "notes.txt"), "kept\n")
    {:ok, _seq} = Log.append(sid, ["root"], :goal_set, %{"text" => "kept too"})

    manager = Sessions.whereis(sid)
    before = Manager.status(manager)
    Troupe.subscribe(sid)

    assert {:ok, %{"restarted" => true, "bundle_version" => 14}} =
             Commands.handle("session.restart", raise_push(sid))

    after_restart = Manager.status(manager)
    assert after_restart.pid != before.pid, "the tree is a new one"
    assert after_restart.sealer == before.sealer and Process.alive?(after_restart.sealer)
    assert after_restart.workspace == before.workspace
    assert File.read!(Path.join(context.workspace, "notes.txt")) == "kept\n"

    events = Troupe.events(sid)
    assert Enum.any?(events, &(&1.type == "goal_set")), "the log before the restart is kept"
    refute Enum.any?(events, &(&1.type == "session_dormant")), "it never slept"

    assert [upgraded] = Enum.filter(events, &(&1.type == "config_upgraded"))

    assert %{"from" => 12, "to" => 14, "reason" => "raised", "by" => "ada@example.test", "by_name" => "Ada"} =
             upgraded.data

    # This process's subscription, and the manager's and the sealer's, are by the session's
    # id: each hears the new tree's events, and the sealer seals them.
    assert_receive {:troupe_event, ^sid, %{type: "config_upgraded"}}, 5_000
    assert %{"bundle_version" => 14} = await_status(&(&1["bundle_version"] == 14))
    assert {:ok, %{sealed_through: through}} = Sealer.seal_now(after_restart.sealer)
    assert through >= upgraded.seq

    # A command arriving now reaches the new tree, as after a wake.
    assert {:ok, tree} = Sessions.running(sid)
    assert tree == Troupe.Registry.whereis({:session, sid})
    assert :ok = Troupe.send_input(sid, "carry on")
    await_event(sid, :turn_ended, 10_000)
  end

  test "a busy session keeps the raise and takes it when its root comes to rest", context do
    sid = context.sid
    slow = fake([], delay_ms: 1_500)
    {:ok, _} = activate(context, bundle: @v12, report: reporter_to(self()), fake: slow)
    Troupe.subscribe(sid)

    :ok = Troupe.send_input(sid, "take your time")
    await_state(sid, [:thinking], 5_000)

    assert {:ok, %{"pending" => true, "status" => status}} =
             Commands.handle("session.restart", raise_push(sid))

    assert status in ["thinking", "acting"]
    refute Enum.any?(Troupe.events(sid), &(&1.type == "config_upgraded"))

    await_event(sid, :config_upgraded, 15_000)
    events = Troupe.events(sid)
    ended = Enum.find_index(events, &(&1.type == "turn_ended"))
    moved = Enum.find_index(events, &(&1.type == "config_upgraded"))
    assert ended < moved, "the turn ended before the tree started again"
    assert %{"bundle_version" => 14} = await_status(&(&1["bundle_version"] == 14))
  end

  test "a tree that does not come back on the raised version puts the session to sleep", context do
    sid = context.sid
    {:ok, _} = activate(context, bundle: @v12, report: reporter_to(self()), fake: fake([]))
    manager = Sessions.whereis(sid)
    reference = Process.monitor(manager)

    assert {:error, %{message: "invalid_params", data: %{reason: "agent_not_here"}}} =
             Commands.handle("session.restart", Map.put(raise_push(sid), "agent", "no-such-agent"))

    assert_receive {:DOWN, ^reference, :process, ^manager, :normal}, 30_000
    assert_receive {:sealed, %{"type" => "session.dormant", "session_id" => ^sid}}, 30_000
    assert Sessions.whereis(sid) == nil
  end

  test "a session not up here, or at another epoch, is not restarted", context do
    assert {:error, %{message: "not_found"}} = Commands.handle("session.restart", raise_push(context.sid))

    {:ok, _} = activate(context, bundle: @v12, fake: fake([]))

    assert {:error, %{message: "conflict"}} =
             Commands.handle("session.restart", Map.put(raise_push(context.sid), "epoch", 7))
  end

  defp raise_push(sid),
    do: %{
      "session_id" => sid,
      "epoch" => 1,
      "profile" => "fixing",
      "channel" => "stable",
      "bundle_version" => 14,
      "bundle_upgraded_from" => 12,
      "bundle_upgrade_reason" => "raised",
      "bundle_upgraded_by" => "ada@example.test",
      "bundle_upgraded_by_name" => "Ada",
      "entitlements" => %{"agents" => ["build", "plan"], "skills" => [], "mcp_servers" => []}
    }

  defp fake(steps, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Fake, [steps: steps, default: {:text, "done"}] ++ opts},
        id: {Fake, System.unique_integer([:positive])}
      )
    )
  end

  defp await_state(sid, states, timeout) do
    wanted = Enum.map(states, &to_string/1)

    receive do
      {:troupe_event, ^sid, %{type: "agent_state", agent: ["root"], data: %{"state" => state}}} ->
        if state in wanted, do: :ok, else: await_state(sid, states, timeout)
    after
      timeout -> flunk("the root never reached #{inspect(states)}")
    end
  end

  defp await_event(sid, type, timeout) do
    wanted = to_string(type)

    receive do
      {:troupe_event, ^sid, %{type: ^wanted} = event} -> event
    after
      timeout -> flunk("no #{wanted} within #{timeout}ms")
    end
  end

  defp await_status(predicate, timeout \\ 15_000) do
    receive do
      {:sealed, %{"type" => "session.status"} = report} ->
        if predicate.(report), do: report, else: await_status(predicate, timeout)

      {:sealed, _other} ->
        await_status(predicate, timeout)
    after
      timeout -> flunk("no matching session.status within #{timeout}ms")
    end
  end
end
