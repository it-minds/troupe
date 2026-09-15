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

  # A restart used to mint a new call_id and log a second `budget_ask_started`, so
  # every UI folded a duplicate pending item that no answer could ever remove.
  test "restarting an agent re-registers its budget question under the same id, logging none" do
    ws = tmp_workspace(%{"f.txt" => "x"})
    script = List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 10)
    {sid, _fake, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "code", %{prompt: "loop", budget: %{max_turns: 1}})

    ask = await_event(path, :budget_ask_started)
    await_state(path, :needs_input)

    call_id = ask.data.call_id
    old = Troupe.agent_pid(sid, path)
    Process.exit(old, :kill)

    # Re-registered under the original id, against the restarted process.
    eventually(fn ->
      live = Troupe.agent_pid(sid, path)

      live && live != old &&
        Enum.any?(Session.Approvals.pending(sid), &(&1.call_id == call_id and &1.agent_pid == live))
    end)

    assert [^ask] = events_of(sid, path, :budget_ask_started)

    # So the id the UI still holds answers the restarted agent, rather than the late
    # DOWN from the dead one having orphaned the request.
    eventually(fn -> Troupe.approve(sid, call_id, :deny) == :ok end)
    await_state(path, :done_unread, 15_000)
    assert window(sid, path).reason == :budget_exhausted
  end

  # The options a question offered are part of the request, so a restart has to
  # put them back in front of the user rather than degrade it to a blank box.
  test "restarting an agent re-registers its question with the options it offered" do
    ws = tmp_workspace()

    script = [
      {:tool, "ask_user",
       %{
         "question" => "Which database?",
         "options" => ["postgres", "sqlite"],
         "multiple" => true
       }},
      {:finish, "chose"}
    ]

    {sid, _fake, _} = start_session!(workspace: ws, script: script)
    {:ok, path} = Troupe.dispatch(sid, "code", "ask me")

    asked = await_event(path, :question_asked)
    await_state(path, :needs_input)

    # The log carries the normalised offer, so any later reader agrees with the UI.
    assert Enum.map(asked.data.options, & &1.label) == ["postgres", "sqlite"]
    assert asked.data.multiple

    call_id = asked.data.call_id
    old = Troupe.agent_pid(sid, path)
    Process.exit(old, :kill)

    eventually(fn ->
      live = Troupe.agent_pid(sid, path)

      live && live != old &&
        Enum.any?(Session.Approvals.pending(sid), fn p ->
          p.call_id == call_id and p.agent_pid == live and
            Enum.map(p.payload.options, & &1.label) == ["postgres", "sqlite"] and
            p.payload.multiple
        end)
    end)

    # Asked once, not twice: no duplicate pending item for the user to puzzle over.
    assert [^asked] = events_of(sid, path, :question_asked)

    eventually(fn -> Troupe.answer(sid, call_id, "postgres, sqlite") == :ok end)
    await_state(path, :done_unread, 15_000)
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
