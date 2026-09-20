defmodule Troupe.Agent.LimitsTest do
  @moduledoc """
  Every way a turn can stop that is not the agent choosing to finish, short of the budget:
  the output cap, an empty reply, a refusal, and the model's context window (Decision
  659). The shape each has to have: never silently lose work, and say what happened in
  words somebody can act on.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Message

  @overflow {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

  defp finish(summary), do: {:text_and_tools, "done", [{"finish", %{"summary" => summary}}]}

  defp run(context, steps, overrides \\ []) do
    %{session: session, fake: fake} = start_session(context, steps: steps, config_overrides: overrides)
    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")
    {sid, fake}
  end

  defp await_done(sid) do
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: done}},
                   10_000

    done
  end

  defp last_prompt_text(fake) do
    request = fake |> Fake.requests() |> List.last()
    request.messages |> List.last() |> Message.text()
  end

  describe "the output cap" do
    test "a reply cut off with no tool call is asked again once and then ends visibly", context do
      cut = {:stop, :max_tokens, {:text, ""}}
      {sid, fake} = run(context, [cut, cut])

      done = await_done(sid)
      assert done["reason"] == "output_truncated"
      assert done["summary"] =~ "output token cap"

      assert [first, second] = events_of_type(sid, :truncated)
      assert first.data["reason"] == "max_tokens"
      assert first.data["note"] =~ "output token cap"
      assert second.data["final"] == true

      assert last_prompt_text(fake) =~ "cut off because it reached the output token cap"
      assert [%{data: %{"source" => "harness"}}] = events_of_type(sid, :user_input) |> Enum.filter(&(&1.data["source"] == "harness"))
    end

    test "a reply that recovers after the note finishes normally", context do
      {sid, _fake} = run(context, [{:stop, :max_tokens, {:text, "half a"}}, finish("smaller steps")])

      done = await_done(sid)
      assert done["reason"] == "finished"
      assert done["summary"] == "smaller steps"
      assert [%{data: %{"note" => _}}] = events_of_type(sid, :truncated)
    end

    test "a tool call cut off mid-argument is answered with an error, not run", context do
      cut_call = {:tools, [{"read_file", %{"__malformed_arguments__" => "{\"path\": \"f.t"}}]}
      {sid, _fake} = run(context, [{:stop, :max_tokens, cut_call}, finish("ok")])

      done = await_done(sid)
      assert done["reason"] == "finished"

      assert [%{data: %{"ok" => false, "content" => content}} | _] = events_of_type(sid, :tool_call_completed)
      assert content =~ "cut off mid-argument"
      assert [%{data: %{"calls" => 1}}] = events_of_type(sid, :truncated)
    end

    test "a refusal ends the agent as refused, not as a successful finish", context do
      {sid, _fake} = run(context, [{:stop, :refusal, {:text, "I can't help with that."}}])

      done = await_done(sid)
      assert done["reason"] == "refused"
      assert done["summary"] =~ "refused to answer: I can't help with that."
    end
  end

  describe "an empty reply" do
    test "a reasoning-only reply is nudged once and then ends visibly", context do
      thought = {:reasoning, "hmm, let me think about this", nil}
      {sid, fake} = run(context, [thought, thought])

      done = await_done(sid)
      assert done["reason"] == "empty_reply"
      assert done["summary"] =~ "no text and no tool call"

      assert [first, second] = events_of_type(sid, :truncated)
      assert first.data["reason"] == "empty"
      assert first.data["note"] =~ "no text and no tool call"
      assert second.data["final"] == true
      assert last_prompt_text(fake) =~ "nothing to act on"
    end

    test "the nudge is available again once a turn has produced something", context do
      steps = [{:reasoning, "…", nil}, {:tools, [{"todo_read", %{}}]}, {:reasoning, "…", nil}, finish("ok")]
      {sid, _fake} = run(context, steps)

      assert await_done(sid)["reason"] == "finished"
      assert length(events_of_type(sid, :truncated)) == 2
    end
  end

  describe "context overflow" do
    # Four tool turns so there is something old enough to summarise; the summariser's
    # own answer is a step too.
    defp long_turns, do: List.duplicate({:tools, [{"todo_read", %{}}]}, 4)

    test "a 400 for a prompt too long compacts once and sends the turn again", context do
      steps = long_turns() ++ [@overflow, {:text, "summary of earlier work"}, finish("recovered")]
      {sid, _fake} = run(context, steps)

      done = await_done(sid)
      assert done["reason"] == "finished"
      assert done["summary"] == "recovered"
      assert [%{data: %{"reason" => "context_overflow"}}] = events_of_type(sid, :compacted)
      assert events_of_type(sid, :llm_error) == []
    end

    test "overflowing again after compacting fails with a line that says what to do", context do
      steps = long_turns() ++ [@overflow, {:text, "summary of earlier work"}, @overflow]
      {sid, _fake} = run(context, steps)

      await_state(sid, [:idle], 10_000)
      assert [%{data: %{"reason" => reason}}] = events_of_type(sid, :llm_error)
      assert reason =~ "no longer fits the model's context window"
      assert reason =~ "compacted once"
      assert length(events_of_type(sid, :compacted)) == 1
    end

    test "too few messages to compact says so rather than compacting nothing", context do
      {sid, _fake} = run(context, [@overflow])

      await_state(sid, [:idle], 10_000)
      assert [%{data: %{"reason" => reason}}] = events_of_type(sid, :llm_error)
      assert reason =~ "too few messages to compact"
      assert events_of_type(sid, :compacted) == []
    end
  end
end
