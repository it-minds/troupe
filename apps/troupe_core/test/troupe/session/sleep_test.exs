defmodule Troupe.Session.SleepTest do
  @moduledoc """
  A session nobody is watching goes to sleep, including one waiting on a person, and what
  it was waiting on comes back with it (#119).

  Waiting on an approval, a question or the budget's question used to count as busy, so a
  session left asking held its tree — and the daemon, which stays up while any tree is
  live — until somebody answered. Nothing is lost by sleeping instead: the request is in
  the log, the call is re-dispatched on the way back, and an answer given before it has
  gone back out is kept for it. What never sleeps is a turn: a model call or a tool
  running.

  The sweeping is a private `Troupe.Sessions.Index` with clocks short enough to test,
  sweeping the real session; the application's own index is left alone. The test follows
  a session's events as `:internal`, so that it sees them without counting as somebody
  watching.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Events
  alias Troupe.Session.{Approvals, Log, Questions}
  alias Troupe.Sessions.Index

  # Watched: an hour. Unwatched: at once, near enough.
  @short [session_idle_ms: :timer.hours(1), detached_idle_ms: 100]

  describe "a session waiting on a person, with nobody watching" do
    test "sleeps, and the approval comes back with it and resumes the turn when answered",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "later"}}]}, {:text, "carried on"}]
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "ask me")
      %{data: %{"call_id" => call_id}} = await_event(sid, :approval_requested)

      index = sweep(context, session, @short)
      asleep(sid)

      # Asleep with the call still open: nothing closed it off as interrupted, and the
      # listing says what it is doing, which is waiting.
      types = context |> logged(sid) |> Enum.map(& &1.type)
      assert "session_dormant" in types
      refute "tool_call_completed" in types
      assert %{state: :dormant, status: :waiting} = GenServer.call(index, {:get, sid})

      wake(context, session, fake, auto_approve: false)

      # Asked again, under the same id, in front of whoever is watching now.
      assert %{data: %{"call_id" => ^call_id}} = await_event(sid, :approval_requested)
      Troupe.approve(sid, call_id, :allow)

      assert %{data: %{"call_id" => ^call_id, "ok" => true, "content" => "approved: later"}} =
               await_event(sid, :tool_call_completed)

      await_event(sid, :llm_response)
      assert Fake.call_count(fake) == 2
    end

    test "sleeps, and the question comes back with it and resumes the turn when answered",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools,
             [{"ask_user", %{"question" => "Which colour?", "options" => ["red", "blue"]}}]},
            {:text, "Blue it is."}
          ]
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "pick a colour")
      %{data: %{"call_id" => call_id}} = await_event(sid, :question_asked)

      index = sweep(context, session, @short)
      asleep(sid)
      assert %{state: :dormant, status: :waiting} = GenServer.call(index, {:get, sid})

      # Before, a question on the way back was closed off as interrupted: only approvals
      # counted as waiting on a person (Decision 651 says a question outlives dormancy).
      wake(context, session, fake)

      assert %{data: %{"call_id" => ^call_id, "question" => "Which colour?"}} =
               await_event(sid, :question_asked)

      assert [%{call_id: ^call_id}] = Questions.pending(sid)
      Troupe.answer(sid, call_id, "blue")

      assert %{data: %{"call_id" => ^call_id, "ok" => true} = completed} =
               await_event(sid, :tool_call_completed)

      assert (completed["result"] || completed["content"]) =~ "blue"
      await_event(sid, :llm_response)
      assert Fake.call_count(fake) == 2
    end

    test "sleeps on a spent budget's question, and is asked it again when it wakes", context do
      tools = List.duplicate({:tools, [{"todo_read", %{}}]}, 2)

      %{session: session, fake: fake} =
        start_session(context, steps: tools, config_overrides: [max_turns: 1])

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "keep going")
      assert %{data: %{"call_id" => "budget-1"}} = await_event(sid, :question_asked)
      assert %{state: :waiting} = Troupe.snapshot(sid)

      index = sweep(context, session, @short)
      asleep(sid)
      assert %{state: :dormant, status: :waiting} = GenServer.call(index, {:get, sid})

      wake(context, session, fake, max_turns: 1)

      # The same question under the same id, and no model call while the budget is spent.
      assert %{data: %{"call_id" => "budget-1"}} = await_event(sid, :question_asked)
      assert Fake.call_count(fake) == 1

      Troupe.answer(sid, "budget-1", "allow")

      assert %{data: %{"call_id" => "budget-1", "decision" => "allow"}} =
               await_event(sid, :budget_ask_answered)

      await_event(sid, :llm_response)
      assert Fake.call_count(fake) == 2
    end

    # Decision 687: the failure guard's question waits where the budget's does, so it sleeps
    # and comes back the same way.
    test "sleeps on the failure guard's question, and is asked it again when it wakes", context do
      failing = List.duplicate({:tools, [{"read_file", %{"path" => "missing.txt"}}]}, 6)
      guard = [tool_failures_note_at: 0, tool_failures_stop_at: 3]

      %{session: session, fake: fake} =
        start_session(context, steps: failing, config_overrides: guard)

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "read it")
      assert %{data: %{"call_id" => "failures-1"}} = await_event(sid, :question_asked)
      assert %{state: :waiting} = Troupe.snapshot(sid)

      index = sweep(context, session, @short)
      asleep(sid)
      assert %{state: :dormant, status: :waiting} = GenServer.call(index, {:get, sid})

      {:ok, woken} = wake(context, session, fake, guard)

      # The same question under the same id, and no model call until it is answered.
      assert %{data: %{"call_id" => "failures-1", "question" => question}} =
               await_event(sid, :question_asked)

      assert question =~ "read_file has failed 3 times in a row"
      assert Fake.call_count(fake) == 3

      Troupe.answer(sid, "failures-1", "stop")

      assert %{data: %{"call_id" => "failures-1", "decision" => "stop"}} =
               await_event(sid, :tool_failures_ask_answered)

      assert %{data: %{"reason" => "tool_failures"}} = await_event(sid, :turn_ended)
      assert Fake.call_count(fake) == 3

      # Stopped, it sleeps again as a session at rest, and waking it takes nothing up: the
      # turn the guard stopped is not one the model is owed.
      index = sweep(context, woken, @short)
      asleep(sid)
      assert %{state: :dormant, status: :idle} = GenServer.call(index, {:get, sid})
      wake(context, session, fake, guard)
      assert %{data: %{"interrupted" => false}} = await_event(sid, :agent_restarted)

      # Long enough for a turn it wrongly took up to have asked the model, or the question.
      Process.sleep(300)
      assert length(events_of_type(sid, :llm_request)) == 3
      assert length(events_of_type(sid, :question_asked)) == 2

      assert Fake.call_count(fake) == 3
    end
  end

  describe "a session somebody is watching" do
    test "is not put to sleep on the short clock, and is once they leave", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "watched"}}]}]
        )

      sid = session.id
      :ok = Troupe.subscribe(sid)
      Troupe.send_input(sid, "ask me")
      await_event(sid, :approval_requested)

      sweep(context, session, @short)

      # Many sweeps, every one of them past the short clock.
      Process.sleep(500)
      assert %{state: :acting} = Troupe.snapshot(sid)
      assert events_of_type(sid, :session_dormant) == []

      :ok = Troupe.unsubscribe(sid)
      asleep(sid)
    end
  end

  describe "a session with something running" do
    test "never sleeps mid-turn, watched or not, and sleeps once the turn is over", context do
      %{session: session} =
        start_session(context,
          delay_ms: 300,
          steps: [{:tools, [{"shell", %{"command" => "sleep 1"}}]}, {:text, "all done"}]
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "run something slow")
      await_event(sid, :llm_request)
      sweep(context, session, session_idle_ms: 50, detached_idle_ms: 50)

      asleep(sid, 10_000)

      # Every step of the turn is in the log before the tree came down: two model calls,
      # the tool's result, and only then the sleep.
      events = logged(context, sid)
      types = Enum.map(events, & &1.type)
      dormant = Enum.find_index(types, &(&1 == "session_dormant"))

      assert Enum.count(Enum.take(types, dormant), &(&1 == "llm_response")) == 2
      assert [%{data: %{"ok" => true}}] = Enum.filter(events, &(&1.type == "tool_call_completed"))
    end
  end

  describe "a session whose subagent is waiting on a person" do
    # A delegation is closed off as interrupted when a tree comes back, so sleeping would
    # lose the subagent's work; its question times out with its tool instead, as before.
    test "stays awake", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          routes: %{
            "root" => [{:tools, [{"delegate", %{"agent" => "general", "task" => "ask"}}]}],
            "general" => [{:tools, [{"needs_approval", %{"note" => "child"}}]}]
          }
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "go")
      assert %{agent: [_root, _child]} = await_event(sid, :approval_requested)

      sweep(context, session, @short)
      Process.sleep(500)
      assert %{state: :acting} = Troupe.snapshot(sid)
    end
  end

  describe "an answer given before the call has asked again" do
    # A person answering a dormant session's request is what wakes it, so the answer can
    # reach the gate before the re-dispatched call does. Here the gate is up and the agent
    # is not, which is that moment held still.
    test "an approval is kept for the call, and it is not asked twice", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "early"}}]}]
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "ask me")
      %{data: %{"call_id" => call_id}} = await_event(sid, :approval_requested)
      sweep(context, session, @short)
      asleep(sid)

      gate(context, session, Approvals)
      :ok = Approvals.decide(sid, call_id, :allow)

      request = %{call_id: call_id, tool: "needs_approval", args: %{}, agent_path: ["root"]}
      asked = Task.async(fn -> Approvals.request(sid, request) end)

      assert Task.yield(asked, 2_000) == {:ok, :allow},
             "the answer was dropped, and the call is waiting for it again"

      assert [%{data: %{"decision" => "allow"}}] = events_of_type(sid, :approval_decided)
      assert [_] = events_of_type(sid, :approval_requested)
    end

    test "a question's answer is kept for the call, and it is not asked twice", context do
      %{session: session} =
        start_session(context, steps: [{:tools, [{"ask_user", %{"question" => "Ship it?"}}]}])

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "ask me")
      %{data: %{"call_id" => call_id}} = await_event(sid, :question_asked)
      sweep(context, session, @short)
      asleep(sid)

      gate(context, session, Questions)
      :ok = Troupe.answer(sid, call_id, "yes")

      question = %{
        call_id: call_id,
        agent_path: ["root"],
        question: "Ship it?",
        options: [],
        multiple: false
      }

      asked = Task.async(fn -> Questions.ask(sid, question) end)

      assert Task.yield(asked, 2_000) == {:ok, {:ok, "yes"}},
             "the answer was dropped, and the call is waiting for it again"

      assert [%{data: %{"text" => "yes"}}] = events_of_type(sid, :question_answered)
      assert [_] = events_of_type(sid, :question_asked)
    end

    test "an answer to something never asked is not kept", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "asked"}}]}]
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "ask me")
      await_event(sid, :approval_requested)
      sweep(context, session, @short)
      asleep(sid)

      gate(context, session, Approvals)
      :ok = Approvals.decide(sid, "toolu_never_asked", :allow)

      Process.sleep(100)
      assert events_of_type(sid, :approval_decided) == []
    end
  end

  describe "a turn cancelled while it waited on a person" do
    test "is not asked again when the session wakes: the cancel closed the call", context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "cancelled"}}]}]
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "ask me")
      %{data: %{"call_id" => call_id}} = await_event(sid, :approval_requested)
      Troupe.cancel(sid)
      await_event(sid, :cancelled)

      index = sweep(context, session, @short)
      asleep(sid)
      assert %{state: :dormant, status: :idle} = GenServer.call(index, {:get, sid})

      wake(context, session, fake, auto_approve: false)
      await_event(sid, :agent_restarted)

      # Whatever the woken agent was going to do, it has done by the time it answers.
      assert %{state: :idle} = Troupe.snapshot(sid)

      assert [%{data: %{"ok" => false, "content" => "cancelled" <> _}}] =
               sid |> events_of_type(:tool_call_completed) |> Enum.filter(&(&1.data["call_id"] == call_id))

      assert [_] = events_of_type(sid, :approval_requested)
      assert Approvals.pending(sid) == []
      assert Fake.call_count(fake) == 1
    end
  end

  describe "what a dormant session's listing says" do
    test "a subagent that finished has not finished the session", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "general", "task" => "look"}}]},
              {:text, "carried on after it"}
            ],
            "general" => [{:text_and_tools, "found it", [{"finish", %{"summary" => "found it"}}]}]
          }
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "go")
      await_state(sid, [:idle], 10_000)
      assert [%{agent: [_root, _child]}] = events_of_type(sid, :agent_done)

      :ok = Troupe.stop_session(sid)
      asleep(sid)

      assert %{state: :dormant, status: :idle} = GenServer.call(listing(context), {:get, sid})
    end

    test "a subagent a cancel took down leaves nothing interrupted", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          routes: %{
            "root" => [{:tools, [{"delegate", %{"agent" => "general", "task" => "ask"}}]}],
            "general" => [{:tools, [{"needs_approval", %{"note" => "child"}}]}]
          }
        )

      sid = session.id
      follow(sid)
      Troupe.send_input(sid, "go")
      assert %{agent: [_root, _child]} = await_event(sid, :approval_requested)
      Troupe.cancel(sid)
      await_event(sid, :cancelled)

      :ok = Troupe.stop_session(sid)
      asleep(sid)

      assert %{state: :dormant, status: :idle} = GenServer.call(listing(context), {:get, sid})
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Seeing the session's events without counting as somebody watching it.
  defp follow(sid), do: :ok = Events.subscribe(sid, :internal)

  # A dormant session is only its log, which is under this test's state directory.
  defp logged(context, sid), do: Log.read_session(sid, context.state_dir)

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

  # An index that only lists, over this test's state directory.
  defp listing(context) do
    opts = [state_dir: context.state_dir, session_idle_ms: :infinity, detached_idle_ms: :infinity]
    start_supervised!(%{id: {Index, make_ref()}, start: {GenServer, :start_link, [Index, opts]}})
  end

  # Stopped, and the registry has let go of its names, so the same id can start again
  # (`stop_session/1` returns before `Registry` has noticed the exit; see ReopeningTest).
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
  defp wake(context, session, fake, overrides \\ []) do
    {:ok, _} =
      Troupe.resume(session.id,
        workspace: context.workspace,
        fake: fake,
        config_overrides:
          [provider: "fake", model: "fake-model", state_dir: context.state_dir] ++ overrides
      )
  end

  # The log and one gate, which is how far a waking tree has got before its agent is back.
  defp gate(context, session, module) do
    start_supervised!(
      {Log,
       session_id: session.id,
       workspace_root: session.workspace.root_real,
       state_dir: context.state_dir}
    )

    start_supervised!({module, session_id: session.id})
  end

  defp drain do
    receive do
      {:troupe_event, _sid, _event} -> drain()
    after
      0 -> :ok
    end
  end

  defp eventually(fun, timeout), do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end
end
