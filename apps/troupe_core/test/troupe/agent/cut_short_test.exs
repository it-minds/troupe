defmodule Troupe.Agent.CutShortTest do
  @moduledoc """
  An agent its budget cuts short stops there, and the session it is in can sleep (#134).

  Nothing more is asked of a subagent that runs out: it makes no further model call, leaves
  nothing running and nothing open in its log, and its parent is handed the plain cut-short
  result (#115) and carries on. Once the parent's turn is over the session sleeps like any
  other nobody is watching (#119), and so does one whose root agent its own budget stopped.

  Every agent here is scripted to call tools for longer than its budget lasts, so a request
  after the cut would take one of the steps left over. The sweeping is a private
  `Troupe.Sessions.Index` on short clocks, as in `Troupe.Session.SleepTest`, and the test
  follows the session's events as `:internal`, so that nobody counts as watching.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Events
  alias Troupe.Session.{Log, Questions}
  alias Troupe.Sessions.Index

  # Watched: an hour. Unwatched: at once, near enough.
  @short [session_idle_ms: :timer.hours(1), detached_idle_ms: 100]

  @child ["root", "general#1"]

  # More than any budget below allows, so a script that ran out is never what stopped an
  # agent.
  @steps 20

  describe "a subagent cut short by its budget" do
    # The subagent's slice: the turns its parent was first given, and a quarter of the
    # tokens and time its parent has left. The fake bills 100 input tokens a request and
    # output tokens by length; `delay_ms` is time for the clock to run out on.
    for {limit, budget, delay_ms} <- [
          {"max_turns", [max_turns: 4], 0},
          {"max_input_tokens", [max_input_tokens: 1_200], 0},
          {"max_output_tokens", [max_output_tokens: 200], 0},
          {"wall_clock", [wall_clock_ms: 4_000], 150}
        ] do
      @tag limit: limit, budget: budget, delay_ms: delay_ms
      test "by #{limit} makes no further model call, leaves nothing running, and sleeps",
           context do
        %{session: session, fake: fake} =
          start_session(context,
            config_overrides: context.budget,
            delay_ms: context.delay_ms,
            routes: %{
              "root" => [
                {:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]},
                {:text, "root done"}
              ],
              "general" =>
                [
                  {:text_and_tools, "Found the retry logic in lib/retry.ex.",
                   [{"todo_read", %{}}]}
                ] ++
                  List.duplicate({:tools, [{"todo_read", %{}}]}, @steps)
            }
          )

        sid = session.id
        follow(sid)
        Troupe.send_input(sid, "delegate something open-ended")
        await_root_idle(sid, 20_000)

        # The parent is handed the plain cut-short result, and its turn goes on.
        assert %{data: %{"ok" => true, "content" => content}} = delegate_result(sid)

        assert content ==
                 "[cut short: the delegated agent ran out of budget (#{context.limit}), so " <>
                   "this may be incomplete]\n\nFound the retry logic in lib/retry.ex."

        # Its part of the log ends at the cut, with nothing left open.
        child = events_of(sid, @child)

        assert [
                 %{type: "agent_done", data: %{"reason" => "budget_exhausted", "limit" => cut}},
                 %{type: "budget_exhausted"}
               ] = Enum.take(child, -2)

        assert cut == context.limit
        assert open_calls(child) == []
        refute unanswered_request?(child)

        # The requests it made are the ones its log shows, fewer than its script had.
        requests = length(Fake.requests_for(fake, "general"))
        assert requests == Enum.count(child, &(&1.type == "llm_request"))
        assert requests <= @steps

        at_rest(sid, @child)

        # With nobody watching, the session sleeps: nothing is owed on the subagent's behalf.
        index = sweep(context, session, @short)
        asleep(sid)
        assert %{state: :dormant, status: :idle} = GenServer.call(index, {:get, sid})
        eventually(fn -> sid not in Troupe.session_ids() end)

        assert length(Fake.requests_for(fake, "general")) == requests
        assert steps(logged(context, sid, @child)) == steps(child)
      end
    end
  end

  describe "a root agent cut short by its own budget, with nobody attached" do
    test "stops where nobody can answer the budget's question, and sleeps", context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [max_turns: 2, approvals: :deny],
          steps: List.duplicate({:tools, [{"todo_read", %{}}]}, @steps)
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "keep going")

      assert %{data: %{"reason" => "budget_exhausted", "limit" => "max_turns"}} =
               await_event(sid, :agent_done)

      root = events_of(sid, ["root"])
      assert [%{type: "agent_done"}, %{type: "budget_exhausted"}] = Enum.take(root, -2)
      assert [%{data: %{"decision" => "deny"}}] = events_of_type(sid, :budget_ask_answered)
      assert open_calls(root) == []
      refute unanswered_request?(root)
      assert Fake.call_count(fake) == 2

      at_rest(sid, ["root"])

      index = sweep(context, session, @short)
      asleep(sid)
      assert %{state: :dormant, status: :done} = GenServer.call(index, {:get, sid})
      assert Fake.call_count(fake) == 2
    end

    test "sleeps on the budget's question after a subagent of its turn was cut short",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [max_turns: 3],
          routes: %{
            "root" =>
              [{:tools, [{"delegate", %{"agent" => "general", "task" => "look into it"}}]}] ++
                List.duplicate({:tools, [{"todo_read", %{}}]}, @steps),
            "general" => List.duplicate({:tools, [{"todo_read", %{}}]}, @steps)
          }
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "delegate, then keep going")
      assert %{data: %{"call_id" => "budget-1"}} = await_event(sid, :question_asked, 20_000)
      assert %{state: :waiting} = Troupe.snapshot(sid)

      assert delegate_result(sid).data["content"] =~ "ran out of budget (max_turns)"
      at_rest(sid, @child)
      requests = Fake.call_count(fake)

      # Parked on a person, and the subagent that is still up has nothing running: asleep,
      # and asked the question again when it wakes.
      index = sweep(context, session, @short)
      asleep(sid)
      assert %{state: :dormant, status: :waiting} = GenServer.call(index, {:get, sid})
      assert Fake.call_count(fake) == requests

      {:ok, _} = wake(context, session, fake, max_turns: 3)
      assert %{data: %{"call_id" => "budget-1"}} = await_event(sid, :question_asked)
      assert [%{call_id: "budget-1"}] = Questions.pending(sid)
      assert Fake.call_count(fake) == requests
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Seeing the session's events without counting as somebody watching it.
  defp follow(sid), do: :ok = Events.subscribe(sid, :internal)

  defp delegate_result(sid) do
    sid
    |> events_of_type(:tool_call_completed)
    |> Enum.find(&(&1.data["name"] == "delegate"))
  end

  # One agent's part of the log of a running session, and of a dormant one, which is only
  # its log under this test's state directory.
  defp events_of(sid, path), do: sid |> Troupe.events() |> Enum.filter(&(&1.agent == path))

  defp logged(context, sid, path),
    do: sid |> Log.read_session(context.state_dir) |> Enum.filter(&(&1.agent == path))

  defp steps(events), do: Enum.map(events, &{&1.seq, &1.type})

  defp open_calls(events) do
    events
    |> Enum.reduce(MapSet.new(), fn
      %{type: "tool_call_started", data: %{"call_id" => id}}, open -> MapSet.put(open, id)
      %{type: "tool_call_completed", data: %{"call_id" => id}}, open -> MapSet.delete(open, id)
      _event, open -> open
    end)
    |> MapSet.to_list()
  end

  defp unanswered_request?(events) do
    events
    |> Enum.filter(&(&1.type in ["llm_request", "llm_response", "llm_error"]))
    |> List.last()
    |> case do
      %{type: "llm_request"} -> true
      _ -> false
    end
  end

  # At rest: no model call in flight and no timer that could start one, no task and no
  # subagent under it, and nothing waiting in its mailbox.
  defp at_rest(sid, path) do
    eventually(fn ->
      Task.Supervisor.children(Registry.tasks(sid, path)) == [] and
        DynamicSupervisor.which_children(Registry.children_sup(sid, path)) == []
    end)

    pid = Registry.agent_pid(sid, path)
    assert {_state, data} = :sys.get_state(pid)
    assert %{llm_ref: nil, llm_timer: nil, budget_ask_task: nil} = data
    assert Enum.all?(Map.values(data.pending), &(is_nil(&1.timer) and &1.result != nil))
    assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
  end

  # The root is idle only once every delegation has come back.
  defp await_root_idle(sid, timeout) do
    receive do
      {:troupe_event, ^sid,
       %Event{type: "agent_state", agent: ["root"], data: %{"state" => "idle"}}} ->
        if Troupe.snapshot(sid).outstanding == [], do: :ok, else: await_root_idle(sid, timeout)

      _other ->
        await_root_idle(sid, timeout)
    after
      timeout -> raise "timed out waiting for the root agent to go idle"
    end
  end

  defp sweep(context, session, clocks) do
    index =
      start_supervised!(%{
        id: {Index, make_ref()},
        start:
          {GenServer, :start_link,
           [Index, [state_dir: context.state_dir, sweep_ms: 20] ++ clocks]}
      })

    GenServer.cast(
      index,
      {:register, session.id, session.pid, %{workspace: context.workspace, profile: "build"}}
    )

    index
  end

  # Stopped, and the registry has let go of its names, so the same id can start again.
  defp asleep(sid, timeout \\ 5_000) do
    eventually(
      fn ->
        Troupe.snapshot(sid) == {:error, :no_agent} and
          is_nil(Registry.whereis({:session, sid})) and is_nil(Registry.whereis({:log, sid}))
      end,
      timeout
    )

    drain()
  end

  # What an activating command does, with this test's model and state directory.
  defp wake(context, session, fake, overrides) do
    Troupe.resume(session.id,
      workspace: context.workspace,
      fake: fake,
      config_overrides:
        [provider: "fake", model: "fake-model", state_dir: context.state_dir] ++ overrides
    )
  end

  defp drain do
    receive do
      {:troupe_event, _sid, _event} -> drain()
    after
      0 -> :ok
    end
  end

  defp eventually(fun, timeout \\ 5_000),
    do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end
end
