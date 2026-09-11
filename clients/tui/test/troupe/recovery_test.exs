defmodule Troupe.RecoveryTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Agent.Node
  alias Troupe.LLM.Fake
  alias Troupe.Session

  # Done item 4
  test "killing the agent server during :acting restarts it from the log; completed calls never run twice" do
    ws = tmp_workspace(%{"f.txt" => "content"})

    script = [
      {:tools,
       [
         {"read_file", %{"path" => "f.txt"}},
         {"todo_write",
          %{"items" => [%{"id" => "1", "content" => "step one", "status" => "in_progress"}]}}
       ]},
      {:tool, "shell", %{"command" => "sleep 1.5; echo slept"}},
      {:finish, "recovered"}
    ]

    {sid, fake, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "code", "do work")

    :ok =
      eventually(fn ->
        if Troupe.agent_pid(sid, path), do: Troupe.switch_profile(sid, path, "worktree")
      end)

    assert_receive {:troupe_event,
                    %{type: :tool_call_started, agent_path: ^path, data: %{name: "shell"}}},
                   5_000

    pid = Troupe.agent_pid(sid, path)
    assert Troupe.Agent.Server.current_state(pid) == :acting
    Process.exit(pid, :kill)

    await_state(path, :done_unread, 15_000)
    assert window(sid, path).summary == "recovered"

    started = events_of(sid, path, :tool_call_started) |> Enum.map(& &1.data.name)
    completed = events_of(sid, path, :tool_call_completed)
    assert Enum.count(started, &(&1 == "read_file")) == 1
    assert Enum.count(started, &(&1 == "todo_write")) == 1

    assert Enum.count(started, &(&1 == "shell")) == 2,
           "shell re-run once after the crash (at-least-once)"

    assert Enum.count(completed, &(&1.data.call_id == "call_1")) == 1

    # state rebuilt: the request after recovery has the whole conversation, the todo list and the switched profile
    last = fake |> Fake.requests() |> List.last()
    assert last.system =~ "step one"
    assert last.system =~ "profile worktree"
    assert length(last.messages) == 5
    assert Enum.count(events_of(sid, path, :assistant_message)) == 3
  end

  # Done item 6
  test "cancel during a shell sleep kills child and grandchild within 1s (by OS pid)" do
    ws = tmp_workspace()
    marker = "60.#{System.unique_integer([:positive])}"

    script = [
      {:tool, "shell", %{"command" => "sleep #{marker} & sleep #{marker}; wait"}},
      {:finish, "x"}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "code", "sleep")

    pids = eventually(fn -> pgrep(marker) |> then(&if(length(&1) >= 2, do: &1)) end)
    assert length(pids) >= 2

    :ok = Troupe.cancel(sid, path)
    t0 = System.monotonic_time(:millisecond)
    eventually(fn -> pgrep(marker) == [] end, 1_000, 10)
    assert System.monotonic_time(:millisecond) - t0 < 1_000
    await_state(path, :done_unread)
    assert window(sid, path).reason == :cancelled
  end

  # Done item 7
  test "SIGKILLing the VM kills the shell child and grandchild within 3s" do
    marker = "61.#{System.unique_integer([:positive])}"
    reaper = Troupe.Reaper.path!()
    # A second Erlang VM owns the reaper Port, exactly like a tool task would.
    eval =
      ~s|Port = open_port({spawn_executable, "#{reaper}"}, [binary, {args, ["bash", "-c", "sleep #{marker} & sleep #{marker}; wait"]}]), io:format("~s~n", [os:getpid()]), receive stop -> Port end.|

    port =
      Port.open({:spawn_executable, System.find_executable("erl")}, [
        :binary,
        :exit_status,
        args: ["-noshell", "-eval", eval]
      ])

    vm_pid =
      receive do
        {^port, {:data, data}} -> data |> String.trim() |> String.to_integer()
      after
        5_000 -> flunk("no pid")
      end

    eventually(fn -> length(pgrep(marker)) >= 2 end)
    System.cmd("kill", ["-9", Integer.to_string(vm_pid)])
    t0 = System.monotonic_time(:millisecond)
    eventually(fn -> pgrep(marker) == [] end, 3_000, 20)
    assert System.monotonic_time(:millisecond) - t0 < 3_000
  end

  # Done item 14
  test "killing a branch Node leaves zero live processes under its subtree" do
    ws = tmp_workspace()
    script = [{:tool, "delegate", %{"agent" => "explore", "prompt" => "look"}}, {:finish, "x"}]
    scripts = %{"code-1/explore-1" => [{:tool, "shell", %{"command" => "sleep 30"}}]}

    {sid, _, _} =
      start_session!(workspace: ws, script: script, scripts: scripts, auto_approve: true)

    {:ok, path} = Troupe.dispatch(sid, "code", "delegate")

    assert_receive {:troupe_event, %{type: :tool_call_started, agent_path: "code-1/explore-1"}},
                   5_000

    node = Session.whereis(sid, {:node, path})
    pids = Node.subtree_pids(node)
    assert length(pids) >= 6
    assert Session.whereis(sid, {:agent, "code-1/explore-1"})

    Process.exit(node, :kill)
    eventually(fn -> Enum.all?(pids, &(not Process.alive?(&1))) end)

    for key <- [
          {:node, path},
          {:agent, path},
          {:tasks, path},
          {:children, path},
          {:node, "code-1/explore-1"},
          {:agent, "code-1/explore-1"}
        ] do
      assert Session.whereis(sid, key) == nil, "#{inspect(key)} still registered"
    end

    await_state(path, :failed_unread)
  end

  defp pgrep(marker) do
    case System.cmd("pgrep", ["-f", "sleep #{marker}"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end
end
