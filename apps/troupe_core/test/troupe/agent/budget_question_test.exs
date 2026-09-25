defmodule Troupe.Agent.BudgetQuestionTest do
  @moduledoc """
  A spent budget is a question for the person attached, not a stop (Decision 660): `allow`
  buys the same slice again, `always` lifts the one limit it was asked about (Decision
  687), `deny` ends the agent; a contract budget and an unattended session behave as
  before; `full_send` never asks.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Server
  alias Troupe.Budget
  alias Troupe.Session.Log

  defp tools(n), do: List.duplicate({:tools, [{"todo_read", %{}}]}, n)
  defp finish(summary), do: {:text_and_tools, "done", [{"finish", %{"summary" => summary}}]}

  defp run(context, steps, overrides) do
    %{session: session, fake: fake} = start_session(context, steps: steps, config_overrides: overrides)
    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "keep going")
    {sid, fake}
  end

  defp await_question(sid, call_id) do
    assert_receive {:troupe_event, ^sid, %Event{type: "question_asked", data: %{"call_id" => ^call_id} = asked}},
                   10_000

    asked
  end

  defp await_done(sid) do
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: done}},
                   10_000

    done
  end

  defp label(option), do: option["label"] || option[:label]

  test "an exhausted budget is a question: allow buys the same slice again, deny stops", context do
    {sid, fake} = run(context, tools(6), max_turns: 2)

    asked = await_question(sid, "budget-1")
    assert asked["question"] =~ "turns 2/2 (100%)"
    assert Enum.map(asked["options"], &label/1) == ["allow", "always", "deny"]
    assert [%{data: %{"dimension" => "turns", "used" => 2, "limit" => 2}}] = events_of_type(sid, :budget_ask_started)

    Troupe.answer(sid, "budget-1", "allow")

    assert_receive {:troupe_event, ^sid,
                    %Event{type: "budget_ask_answered", data: %{"call_id" => "budget-1", "decision" => "allow", "grant" => grant}}},
                   10_000

    assert grant["turns"] == 2

    # The same slice again, then the same question again.
    await_question(sid, "budget-2")
    Troupe.answer(sid, "budget-2", "deny")

    done = await_done(sid)
    assert done["reason"] == "budget_exhausted"
    assert done["limit"] == "max_turns"
    assert Fake.call_count(fake) == 4

    assert %{"budget" => %{"turns" => 4, "max_turns" => 4}} = Server.summary(snapshot_state(sid), :done)
  end

  test "always lifts the limit it was asked about for the rest of the session", context do
    {sid, fake} = run(context, tools(3) ++ [finish("ok")], max_turns: 1)

    await_question(sid, "budget-1")
    Troupe.answer(sid, "budget-1", "always")

    done = await_done(sid)
    assert done["reason"] == "finished"
    assert Fake.call_count(fake) == 4
    assert [%{data: %{"decision" => "always"}}] = events_of_type(sid, :budget_ask_answered)
    assert length(events_of_type(sid, :budget_ask_started)) == 1
  end

  # The fake answers every call with 100 input tokens, so 150 is spent by the second call.
  test "always on input tokens lifts that limit alone: the turn limit still asks", context do
    {sid, fake} = run(context, tools(6), max_input_tokens: 150, max_turns: 4)

    asked = await_question(sid, "budget-1")
    assert asked["question"] =~ "input tokens"
    always = Enum.find(asked["options"], &(label(&1) == "always"))
    assert (always["description"] || always[:description]) == "lift the input-token limit for the rest of the session"

    Troupe.answer(sid, "budget-1", "always")

    assert_receive {:troupe_event, ^sid,
                    %Event{type: "budget_ask_answered", data: %{"decision" => "always", "lifted" => "max_input_tokens"}}},
                   10_000

    asked = await_question(sid, "budget-2")
    assert asked["question"] =~ "turns 4/4"
    assert Fake.call_count(fake) == 4
    assert [_, %{data: %{"dimension" => "turns"}}] = events_of_type(sid, :budget_ask_started)

    Troupe.answer(sid, "budget-2", "deny")
    assert await_done(sid)["limit"] == "max_turns"
  end

  test "always on turns leaves the input-token and time limits asking", context do
    {sid, fake} = run(context, tools(6), max_turns: 1, max_input_tokens: 250)

    assert await_question(sid, "budget-1")["question"] =~ "turns 1/1"
    Troupe.answer(sid, "budget-1", "always")

    assert await_question(sid, "budget-2")["question"] =~ "input tokens"
    assert Fake.call_count(fake) == 3
    Troupe.answer(sid, "budget-2", "deny")
    assert await_done(sid)["limit"] == "max_input_tokens"

    {slow, _fake} = run(context, tools(6), max_turns: 1, wall_clock_ms: 1_500)
    await_question(slow, "budget-1")
    Troupe.answer(slow, "budget-1", "always")
    Process.sleep(1_600)
    Troupe.send_input(slow, "and again")
    assert await_question(slow, "budget-2")["question"] =~ "wall clock"
  end

  test "an always from before the answer said what it lifted folds to the limit its question named", context do
    {sid, _fake} = run(context, tools(6), max_input_tokens: 150, max_turns: 4)
    await_question(sid, "budget-1")

    # What a daemon before Decision 687 wrote: `always` and nothing about which limit.
    Log.append(sid, ["root"], :budget_ask_answered, %{"call_id" => "budget-1", "decision" => "always"})

    agent = Troupe.Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

    # The restarted agent carries on past the input-token limit, and the turn limit it no
    # longer lifts asks when it is reached.
    assert await_question(sid, "budget-2")["question"] =~ "turns 4/4"
    {_state_name, state} = :sys.get_state(await_new_agent(sid, agent, 50))
    assert state.budget.lifted == [:max_input_tokens]
    assert {:exhausted, :max_turns} = Budget.check(state.budget)
  end

  test "a fresh slice warns afresh", context do
    {sid, _fake} = run(context, tools(3) ++ [finish("ok")], max_turns: 2, budget_warn_at: 0.5)

    await_question(sid, "budget-1")
    Troupe.answer(sid, "budget-1", "allow")
    assert await_done(sid)["reason"] == "finished"

    turns = sid |> events_of_type(:budget_warning) |> Enum.filter(&(&1.data["dimension"] == "turns"))
    assert length(turns) == 2, "one warning per slice, not one for the whole session"
  end

  test "an unattended session answers no itself", context do
    {sid, fake} = run(context, tools(2), max_turns: 1, approvals: :deny)

    done = await_done(sid)
    assert done["reason"] == "budget_exhausted"
    assert done["limit"] == "max_turns"
    assert Fake.call_count(fake) == 1
    assert [%{data: %{"decision" => "deny"}}] = events_of_type(sid, :budget_ask_answered)
    # The question is still written, so the transcript shows what was asked and of whom.
    assert [%{data: %{"call_id" => "budget-1"}}] = events_of_type(sid, :question_asked)
  end

  test "a contract budget stops without asking, and full_send never asks", context do
    {sid, fake} = run(context, tools(2), max_turns: 1, budget_asks: false)
    assert await_done(sid)["reason"] == "budget_exhausted"
    assert Fake.call_count(fake) == 1
    assert events_of_type(sid, :question_asked) == []

    {free, fake} = run(context, tools(3) ++ [finish("ok")], max_turns: 1, full_send: true)
    assert await_done(free)["reason"] == "finished"
    assert Fake.call_count(fake) == 4
    assert events_of_type(free, :budget_ask_started) == []
  end

  test "the grant is folded, so a restarted agent keeps the slice it was given", context do
    {sid, _fake} = run(context, tools(6), max_turns: 2)

    await_question(sid, "budget-1")
    Troupe.answer(sid, "budget-1", "allow")
    await_question(sid, "budget-2")

    agent = Troupe.Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

    restarted = await_new_agent(sid, agent, 50)
    {_state_name, state} = :sys.get_state(restarted)
    assert state.budget.max_turns == 4
    assert state.budget_asks == 2
    assert state.budget_ask_pending == "budget-2", "the unanswered question is still owed"
  end

  defp await_new_agent(_sid, _old, 0), do: flunk("the agent was not restarted")

  defp await_new_agent(sid, old, tries) do
    case Troupe.Registry.agent_pid(sid, ["root"]) do
      pid when is_pid(pid) and pid != old -> pid
      _ ->
        Process.sleep(100)
        await_new_agent(sid, old, tries - 1)
    end
  end

  defp snapshot_state(sid) do
    pid = Troupe.Registry.agent_pid(sid, ["root"])
    {_state_name, state} = :sys.get_state(pid)
    state
  end
end
