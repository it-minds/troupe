defmodule Troupe.DispatcherTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake
  alias Troupe.Session

  # Done item 13 (a)
  test "four /code commands run concurrently with distinct paths and all rest done_unread" do
    ws = tmp_workspace()

    fallback = fn req ->
      if length(req.messages) < 3,
        do: {:tool, "shell", %{"command" => "sleep 0.3"}},
        else: {:finish, "ok"}
    end

    {sid, fake, _} = start_session!(workspace: ws, fallback: fallback, auto_approve: true)

    paths = for i <- 1..4, do: Troupe.dispatch(sid, "code", "task #{i}") |> elem(1)
    assert paths == ["code-1", "code-2", "code-3", "code-4"]
    for p <- paths, do: await_state(p, :done_unread)

    first_four = fake |> Fake.requests() |> Enum.take(4) |> Enum.map(& &1.agent_path)
    assert Enum.sort(first_four) == paths, "streams interleaved: #{inspect(first_four)}"
    assert Enum.all?(Troupe.windows(sid), &(&1.state == :done_unread))
  end

  # Done item 13 (b)
  test "a branch crashing past restart intensity is failed_unread while the other three finish" do
    ws = tmp_workspace()

    fallback = fn req ->
      if length(req.messages) < 3,
        do: {:tool, "shell", %{"command" => "sleep 1"}},
        else: {:finish, "ok"}
    end

    {sid, _fake, _} = start_session!(workspace: ws, fallback: fallback, auto_approve: true)
    paths = for i <- 1..4, do: Troupe.dispatch(sid, "code", "task #{i}") |> elem(1)
    victim = "code-2"

    Enum.reduce(1..4, nil, fn _, last ->
      pid =
        eventually(fn ->
          p = Troupe.agent_pid(sid, victim)
          if p && p != last, do: p
        end)

      Process.exit(pid, :kill)
      pid
    end)

    await_state(victim, :failed_unread, 10_000)
    for p <- paths -- [victim], do: await_state(p, :done_unread, 10_000)
    assert window(sid, victim).state == :failed_unread
    assert window(sid, victim).message =~ "shutdown"
  end

  # Done item 15
  @tag timeout: 120_000
  test "truly idle: no commands means zero Fake calls and no Agent.Node; done_unread windows behave the same" do
    ws = tmp_workspace()
    {sid, fake, _} = start_session!(workspace: ws, script: [{:finish, "a"}, {:finish, "b"}])
    {:ok, p1} = Troupe.dispatch(sid, "code", "one")
    {:ok, p2} = Troupe.dispatch(sid, "code", "two")
    await_state(p1, :done_unread)
    await_state(p2, :done_unread)
    eventually(fn -> Session.Branches.live_nodes(sid) == [] end)
    count = Fake.call_count(fake)

    Process.sleep(idle_wait())

    assert Fake.call_count(fake) == count
    assert Session.Branches.live_nodes(sid) == []
    assert Enum.map(Troupe.windows(sid), & &1.state) == [:done_unread, :done_unread]
  end

  defp idle_wait, do: String.to_integer(System.get_env("TROUPE_IDLE_TEST_MS") || "60000")

  # Done item 16
  test "dispatcher crash leaves branches running and rebuilds an identical ledger" do
    ws = tmp_workspace()

    fallback = fn req ->
      if length(req.messages) < 9,
        do: {:tool, "shell", %{"command" => "sleep 0.2"}},
        else: {:finish, "ok"}
    end

    {sid, fake, _} = start_session!(workspace: ws, fallback: fallback, auto_approve: true)
    {:ok, _} = Troupe.dispatch(sid, "code", "a")
    {:ok, _} = Troupe.dispatch(sid, "code", "b")
    eventually(fn -> Fake.call_count(fake) >= 2 end)

    before = Troupe.windows(sid)
    count = Fake.call_count(fake)
    dispatcher = Session.whereis(sid, :dispatcher)
    Process.exit(dispatcher, :kill)

    eventually(fn -> Session.whereis(sid, :dispatcher) not in [nil, dispatcher] end)
    eventually(fn -> Fake.call_count(fake) > count + 1 end)
    after_crash = Troupe.windows(sid)

    assert Enum.map(after_crash, &{&1.agent_path, &1.state}) ==
             Enum.map(before, &{&1.agent_path, &1.state})

    for w <- after_crash, do: await_state(w.agent_path, :done_unread, 10_000)
  end

  # Done item 17
  test "resume restores running, needs_input and done_unread windows and skips dismissed ones" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [{:tool, "shell", %{"command" => "sleep 30"}}, {:finish, "long"}],
      "code-2" => [{:tool, "write_file", %{"path" => "x", "content" => "y"}}, {:finish, "asked"}],
      "code-3" => [{:finish, "done three"}],
      "code-4" => [{:finish, "done four"}]
    }

    fake = Fake.start!([], scripts: scripts)
    {sid, _, _} = start_session!(workspace: ws, fake: fake, config: %{auto_approve: false})
    {:ok, p1} = Troupe.dispatch(sid, "code", "long running")
    req1 = await_event(p1, :approval_requested)
    :ok = Troupe.approve(sid, req1.data.call_id, :allow)

    assert_receive {:troupe_event,
                    %{type: :tool_call_started, agent_path: ^p1, data: %{name: "shell"}}},
                   5_000

    {:ok, p2} = Troupe.dispatch(sid, "code", "needs approval")
    req = await_event(p2, :approval_requested)
    {:ok, p3} = Troupe.dispatch(sid, "code", "quick")
    {:ok, p4} = Troupe.dispatch(sid, "code", "dismissed")
    await_state(p3, :done_unread)
    await_state(p4, :done_unread)
    :ok = Troupe.dismiss(sid, p4)
    count = Fake.call_count(fake)

    :ok = Troupe.stop_session(sid)
    eventually(fn -> Session.whereis(sid, :session) == nil end)

    {:ok, ^sid} =
      Troupe.resume(sid, provider: {Fake, fake}, config: %{memory: %{auto_refresh: false}})

    :ok = Troupe.subscribe(sid)
    on_exit(fn -> Troupe.stop_session(sid) end)

    states = Troupe.windows(sid) |> Map.new(&{&1.agent_path, &1.state})
    assert states == %{p1 => :running, p2 => :needs_input, p3 => :done_unread, p4 => :dismissed}

    # the running branch re-runs its interrupted shell call and finishes
    assert Troupe.agent_pid(sid, p1)
    # the waiting one still waits with the same pending call
    pending = Session.Approvals.pending(sid)
    assert [%{call_id: call_id, agent_path: ^p2}] = pending
    assert call_id == req.data.call_id
    assert Troupe.agent_pid(sid, p3) == nil
    assert Troupe.agent_pid(sid, p4) == nil
    # nothing dismissed comes back as a live window
    refute Enum.any?(Troupe.windows(sid), &(&1.agent_path == p4 and &1.state != :dismissed))

    :ok = Troupe.approve(sid, call_id, :allow)
    await_state(p2, :done_unread)
    assert Fake.call_count(fake) > count
  end

  # Done item 19
  test "the ninth command is refused with a message and no Node is started" do
    ws = tmp_workspace()
    fallback = fn _ -> {:delay, 20_000, {:finish, "x"}} end
    {sid, _, _} = start_session!(workspace: ws, fallback: fallback)
    for i <- 1..8, do: assert({:ok, _} = Troupe.dispatch(sid, "code", "t#{i}"))
    assert {:error, msg} = Troupe.dispatch(sid, "code", "ninth")
    assert msg =~ "max_branches (8)"
    assert length(Session.Branches.live_nodes(sid)) == 8
    assert length(Troupe.windows(sid)) == 8
  end

  # Decision 57
  test "cancel_branch stops a running branch, removes its window and frees the slot" do
    ws = tmp_workspace()
    fallback = fn _ -> {:delay, 20_000, {:finish, "never"}} end
    {sid, _, _} = start_session!(workspace: ws, fallback: fallback)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "long task")
    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "another")
    eventually(fn -> length(Session.Branches.live_nodes(sid)) == 2 end)

    :ok = Troupe.cancel_branch(sid, "code-1")
    await_event("code-1", :window_dismissed)

    assert window(sid, "code-1").state == :dismissed
    assert window(sid, "code-2").state == :running
    assert [cancelled] = events_of(sid, "code-1", :cancelled)
    assert cancelled.agent_path == "code-1"
    eventually(fn -> Session.Branches.live_nodes(sid) |> length() == 1 end)
  end

  # Decision 57
  test "cancel_branch removes a resting window, and refuses one already removed" do
    ws = tmp_workspace()
    {sid, _, _} = start_session!(workspace: ws, scripts: %{"code-1" => [{:finish, "done"}]})

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "quick")
    await_state("code-1", :done_unread)

    :ok = Troupe.cancel_branch(sid, "code-1")
    await_event("code-1", :window_dismissed)
    assert window(sid, "code-1").state == :dismissed

    assert {:error, msg} = Troupe.cancel_branch(sid, "code-1")
    assert msg =~ "was dismissed"
    assert {:error, "no window code-9"} = Troupe.cancel_branch(sid, "code-9")
  end
end
