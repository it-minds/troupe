defmodule Troupe.Agent.ToolFailuresTest do
  @moduledoc """
  The failure guard (Decision 687, issue #117): a tool that keeps failing gets the model a
  note at `tool_failures_note_at` and stops the turn at `tool_failures_stop_at`, with a
  question for the person attached — whatever the budget says, `always` and `full_send`
  included. A success clears the count; a subagent is stopped and reports what it has; a
  session nobody is attached to stops without waiting.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Protocol.Schema

  defp failing(n), do: List.duplicate({:tools, [{"read_file", %{"path" => "missing.txt"}}]}, n)
  defp reading(n), do: List.duplicate({:tools, [{"read_file", %{"path" => "here.txt"}}]}, n)
  defp finish(summary), do: {:text_and_tools, "done", [{"finish", %{"summary" => summary}}]}

  defp run(context, steps, overrides \\ []) do
    write_file(context, "here.txt", "here\n")
    %{session: session, fake: fake} = start_session(context, steps: steps, config_overrides: overrides)
    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "read the file")
    {sid, fake}
  end

  defp await_question(sid, call_id) do
    assert_receive {:troupe_event, ^sid, %Event{type: "question_asked", data: %{"call_id" => ^call_id} = asked}},
                   10_000

    asked
  end

  defp await_turn_ended(sid) do
    assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"], data: data}}, 10_000
    data
  end

  defp notes(sid) do
    for %Event{data: %{"source" => "harness", "text" => text}} <- events_of_type(sid, :user_input), do: text
  end

  defp label(option), do: option["label"] || option[:label]

  defp assert_schema(sid) do
    for event <- Troupe.events(sid) do
      assert Schema.validate_event(event.type, event.data) == :ok,
             "#{event.type} does not match its schema: #{inspect(Schema.validate_event(event.type, event.data))}"
    end
  end

  test "the same failing call gets a note at five and a question at ten; stop ends the turn", context do
    {sid, fake} = run(context, failing(12))

    asked = await_question(sid, "failures-1")
    assert asked["question"] =~ "read_file has failed 10 times in a row"
    assert Enum.map(asked["options"], &label/1) == ["stop", "continue"]
    assert Fake.call_count(fake) == 10, "no model call is made past the tenth failure"

    assert [note] = notes(sid)
    assert note =~ "read_file has failed 5 times in a row"
    assert note =~ "ask the user"

    assert [%{data: %{"call_id" => "failures-1", "tool" => "read_file", "failures" => 10}}] =
             events_of_type(sid, :tool_failures_ask_started)

    Troupe.answer(sid, "failures-1", "stop")

    assert await_turn_ended(sid) == %{"reason" => "tool_failures"}
    assert [%{data: %{"decision" => "stop"}}] = events_of_type(sid, :tool_failures_ask_answered)
    assert Fake.call_count(fake) == 10
    assert List.last(notes(sid)) =~ "stopped this turn because read_file failed 10 times"
    assert events_of_type(sid, :budget_ask_started) == []
    assert_schema(sid)
  end

  test "continue lets it go on, and the count starts again", context do
    {sid, fake} = run(context, failing(12) ++ [finish("gave up")])

    await_question(sid, "failures-1")
    Troupe.answer(sid, "failures-1", "continue")

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: %{"reason" => "finished"}}},
                   10_000

    assert Fake.call_count(fake) == 13
    assert length(events_of_type(sid, :tool_failures_ask_started)) == 1
  end

  test "a success of the tool clears its count", context do
    {sid, fake} = run(context, failing(6) ++ reading(1) ++ failing(9) ++ [{:text, "no luck"}])

    assert await_turn_ended(sid) == %{}
    assert Fake.call_count(fake) == 17
    assert events_of_type(sid, :tool_failures_ask_started) == []
    assert length(notes(sid)) == 2, "one note for each run of five, and no question"
  end

  test "it holds with the budget lifted: full_send", context do
    {sid, fake} = run(context, failing(12), full_send: true)

    await_question(sid, "failures-1")
    assert Fake.call_count(fake) == 10
  end

  test "it holds with the budget lifted: always on the budget question", context do
    {sid, fake} = run(context, failing(12), max_turns: 2)

    await_question(sid, "budget-1")
    Troupe.answer(sid, "budget-1", "always")

    await_question(sid, "failures-1")
    assert Fake.call_count(fake) == 10
    Troupe.answer(sid, "failures-1", "stop")
    assert await_turn_ended(sid) == %{"reason" => "tool_failures"}
  end

  test "an unattended session stops rather than waits", context do
    {sid, fake} = run(context, failing(12), approvals: :deny)

    assert await_turn_ended(sid) == %{"reason" => "tool_failures"}
    assert Fake.call_count(fake) == 10
    assert [%{data: %{"decision" => "stop"}}] = events_of_type(sid, :tool_failures_ask_answered)
    # The question is still written, so the transcript shows what was asked.
    assert [%{data: %{"call_id" => "failures-1"}}] = events_of_type(sid, :question_asked)
  end

  test "the thresholds are the config's, and 0 turns a step off", context do
    {sid, fake} = run(context, failing(4) ++ [{:text, "no luck"}], tool_failures_note_at: 0, tool_failures_stop_at: 3)

    await_question(sid, "failures-1")
    assert Fake.call_count(fake) == 3
    assert notes(sid) == []
  end

  test "a subagent is stopped and hands its parent what it has, without asking", context do
    %{session: session, fake: fake} =
      start_session(context,
        routes: %{
          "root" => [
            {:tools, [{"delegate", %{"agent" => "general", "task" => "find the file"}}]},
            {:text, "root done"}
          ],
          "general" =>
            [{:text_and_tools, "Looking in the usual place.", [{"read_file", %{"path" => "missing.txt"}}]}] ++
              failing(12)
        }
      )

    sid = session.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "delegate it")
    assert await_turn_ended(sid) == %{}

    assert [done] = Enum.filter(events_of_type(sid, :agent_done), &(&1.agent != ["root"]))
    assert done.data["reason"] == "tool_failures"

    result = sid |> events_of_type(:tool_call_completed) |> Enum.find(&(&1.data["name"] == "delegate"))
    assert result.data["ok"]
    assert result.data["content"] =~ "read_file failed 10 times in a row"
    assert result.data["content"] =~ "Looking in the usual place."

    assert events_of_type(sid, :question_asked) == []
    assert length(Fake.requests_for(fake, "general")) == 10
  end

  test "a question still owed is asked again under its own id after a restart", context do
    {sid, _fake} = run(context, failing(12))
    await_question(sid, "failures-1")

    agent = Troupe.Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

    # A crash inside a live session carries on: its turn goes as far as the gate, which
    # asks the same question again rather than making the call it stopped before.
    await_question(sid, "failures-1")
    restarted = Troupe.Registry.agent_pid(sid, ["root"])
    {:waiting, state} = :sys.get_state(restarted)
    assert state.failure_ask == {"read_file", 10}

    Troupe.answer(sid, "failures-1", "stop")
    assert await_turn_ended(sid) == %{"reason" => "tool_failures"}
    assert length(events_of_type(sid, :tool_failures_ask_started)) == 1
  end
end
