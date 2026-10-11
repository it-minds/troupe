Code.require_file("../../support/fake_openai.exs", __DIR__)

defmodule Troupe.Agent.StablePromptTest do
  @moduledoc """
  Issue #465's second option (Decision 815), the default since Decision 863: with
  `system_prompt: stable` the system prompt is the same on every call of a session, and
  what changes between turns (the task list, the instruction files and the brief, the
  goal) goes with the turn instead, in a block of the turn's own message that stays where
  it was put. With `per_turn` it is in the system prompt, as Decisions 792 and 798 have
  it, and changes it between turns.

  The blocks are in the log (Decision 863), so an agent restarted and a session resumed
  send the prefix they sent before.

  The log says, per call, whether the system prompt and the tools changed since the
  agent's call before, which is what `Troupe.Bench.Prefix` counts.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Message, Text}
  alias Troupe.Log.Fold
  alias Troupe.Test.FakeOpenAI

  @list [
    %{"id" => "a", "content" => "read the notes", "status" => "in_progress"},
    %{"id" => "b", "content" => "write the answer", "status" => "pending"}
  ]

  @steps [
    {:tools, [{"todo_write", %{"items" => @list}}]},
    {:text, "listed"},
    {:tools, [{"read_file", %{"path" => "notes.txt"}}]},
    {:text, "done"}
  ]

  setup context do
    write_file(context, "notes.txt", "a tab is two spaces\n")
    write_file(context, "AGENTS.md", "Answer in one sentence.\n")
    :ok
  end

  # Issue #465, decided (Decision 863): a fresh config is stable. The second turn begins with
  # the list the first left and with the instruction files the first had; neither moves
  # the system prompt.
  test "a fresh config sends one system prompt for the whole session", context do
    {sid, requests} = two_turns(context, [])

    assert [{system, nil}] = requests |> Enum.map(&{&1.system, &1.system_tail}) |> Enum.uniq()
    refute system =~ "Answer in one sentence."
    refute system =~ "<task_list>"

    assert changes(sid) == [nil, {false, true}, {false, false}, {false, false}]

    assert sid |> events_of_type(:llm_request) |> Enum.map(& &1.data["turn_context"]) ==
             [["instructions"], nil, ["task_list"], nil]
  end

  test "with system_prompt: per_turn the task list a turn left changes the system prompt the next turn begins with",
       context do
    {sid, [first, second, third, fourth]} = two_turns(context, system_prompt: "per_turn")

    # The list joins the system prompt at the next turn (Decision 792), held for that turn.
    assert Enum.map([first, second], & &1.system_tail) == ["", ""]
    assert third.system_tail =~ "read the notes"
    assert fourth.system_tail == third.system_tail
    assert first.system =~ "Answer in one sentence."

    # And the log says where the prefix changed: the tools at the second call (the list's
    # own are offered once there is a list, Decision 793), the system prompt at the third.
    assert changes(sid) == [nil, {false, true}, {true, false}, {false, false}]
  end

  test "with system_prompt: stable the system prompt is the same on every call of the session",
       context do
    {sid, requests} = two_turns(context, system_prompt: "stable")
    [first, second, third, fourth] = requests

    assert [system] = requests |> Enum.map(&{&1.system, &1.system_tail}) |> Enum.uniq()
    assert {_text, nil} = system
    refute elem(system, 0) =~ "Answer in one sentence."
    refute elem(system, 0) =~ "<task_list>"

    # The instruction files go with the first turn's message, and the list the turn left
    # with the second's; each request is the one before with something added, never
    # changed (the only way a kept thinking block stays valid, #465).
    assert turn_context(first, 0) =~ "Answer in one sentence."
    refute turn_context(first, 0) =~ "<task_list>"
    assert turn_context(third, 4) =~ "read the notes"
    refute turn_context(third, 4) =~ "Answer in one sentence.", "unchanged, not sent again"

    for {before, later} <- [{first, second}, {second, third}, {third, fourth}] do
      assert List.starts_with?(later.messages, before.messages)
    end

    assert changes(sid) == [nil, {false, true}, {false, false}, {false, false}]

    # Which sections went with a call is in its `llm_request`.
    assert sid |> events_of_type(:llm_request) |> Enum.map(& &1.data["turn_context"]) ==
             [["instructions"], nil, ["task_list"], nil]
  end

  test "with system_prompt: stable a goal set between turns goes with the next turn", context do
    %{session: session, fake: fake} =
      start_session(context,
        steps: [{:text, "one"}, {:text, "two"}],
        config_overrides: [system_prompt: "stable"]
      )

    sid = session.id
    Troupe.subscribe(sid)
    turn(sid, "first")
    :ok = Troupe.set_goal(sid, "ship the parser")
    await_event(sid, :goal_set)
    turn(sid, "second")

    [first, second] = Fake.requests(fake)
    assert first.system == second.system
    refute second.system =~ "ship the parser"
    assert turn_context(second, 2) =~ "ship the parser"
    assert List.starts_with?(second.messages, first.messages)
  end

  # The turn contexts are in the log and folded (Decision 863): a call after a restart or a
  # resume sends, byte for byte, the prefix the call before it sent, up to the new turn.
  describe "after a restart" do
    test "a resumed session's first call sends the prefix its last call before the stop sent",
         context do
      %{session: session, fake: fake} = start_session(context, steps: [{:text, "one"}])
      sid = session.id
      Troupe.subscribe(sid)
      :ok = Troupe.set_goal(sid, "ship the parser")
      await_event(sid, :goal_set)
      turn(sid, "first")
      [before] = Fake.requests(fake)
      assert turn_context(before, 0) =~ "Answer in one sentence."
      :ok = stopped(sid)
      drain()

      resumed = start_supervised!({Fake, steps: [{:text, "two"}]}, id: :resumed_fake)

      {:ok, _} =
        Troupe.resume(sid,
          workspace: context.workspace,
          fake: resumed,
          config_overrides: [provider: "fake", auto_approve: true, state_dir: context.state_dir]
        )

      on_exit(fn -> Troupe.stop_session(sid) end)
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "second")
      await_event(sid, :turn_ended, 10_000)

      [after_resume] = Fake.requests(resumed)
      assert_same_prefix(before, after_resume)

      # Nothing changed, so the new turn carries no turn context of its own.
      assert length(after_resume.messages) == length(before.messages) + 2
      assert turn_context(after_resume, length(before.messages) + 1) == ""
    end

    test "an agent restarted between turns sends the prefix it sent before", context do
      %{session: session, fake: fake} =
        start_session(context, steps: [{:text, "one"}, {:text, "two"}])

      sid = session.id
      Troupe.subscribe(sid)
      turn(sid, "first")
      kill_root(sid)
      drain()

      Troupe.send_input(sid, "second")
      await_event(sid, :turn_ended, 10_000)

      [before, after_restart] = Fake.requests(fake)
      assert turn_context(before, 0) =~ "Answer in one sentence."
      assert_same_prefix(before, after_restart)
    end

    test "an agent restarted in the middle of a turn sends the prefix it sent before", context do
      steps = [
        {:tools, [{"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 400}}]},
        {:text, "done after the restart"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "count slowly")
      await_started(sid, "slow")
      kill_root(sid)
      await_reply(sid, "done after the restart")

      [began, restarted] = Fake.requests(fake)
      assert turn_context(began, 0) =~ "Answer in one sentence."
      assert_same_prefix(began, restarted)
    end

    # A compaction empties the turn context as it rewrites the conversation, on replay as
    # live: what a restarted agent puts back is only what was put after it.
    test "after a compaction a restarted agent puts back only what was put after it", context do
      overflow =
        {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:tools, [{"read_file", %{"path" => "notes.txt"}}]},
        overflow,
        {:text, "summary of the work so far"},
        {:text, "four"},
        {:text, "five"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      sid = session.id
      Troupe.subscribe(sid)
      Enum.each(["first", "second", "third", "fourth"], &turn(sid, &1))
      assert [_] = events_of_type(sid, "compacted")
      kill_root(sid)
      drain()

      Troupe.send_input(sid, "fifth")
      await_event(sid, :turn_ended, 10_000)

      [_, _, _, _, _, _summariser, resent, after_restart] = Fake.requests(fake)
      assert Enum.count(resent.messages, &(turn_context_of(&1) != "")) == 1
      assert_same_prefix(resent, after_restart)
    end

    test "the fold witnesses the blocks put, and a log without one folds as it always did" do
      request = %{"model" => "m", "message_count" => 1, "tools" => [], "profile" => "build"}
      put = %{"at" => 0, "text" => "<turn_context>\n...\n</turn_context>", "sent" => %{}}

      base = [witness_event(1, "user_input", %{"source" => "user", "text" => "hi"})]
      plain = base ++ [witness_event(2, "llm_request", request)]

      with_block =
        base ++ [witness_event(2, "llm_request", Map.put(request, "turn_context_block", put))]

      compacted = with_block ++ [witness_event(3, "compacted", %{"conversation" => []})]

      assert Fold.state(plain)["agents"]["root"] == Fold.state(base)["agents"]["root"]
      assert Fold.state(with_block)["agents"]["root"]["turn_contexts"] == 1
      refute Map.has_key?(Fold.state(plain)["agents"]["root"], "turn_contexts")
      refute Map.has_key?(Fold.state(compacted)["agents"]["root"], "turn_contexts")
    end

    # Against the stand-in as Claude Opus 5.5, which binds each thinking block to the
    # conversation it was made in, asked with `thinking_binding: error` (#591) to refuse one
    # sent back after that changed: the first turn's thinking still holds after a resume.
    test "with thinking_binding: error a resumed session is never refused", context do
      stand_in =
        FakeOpenAI.start(
          scripts: [
            {"read the notes",
             [
               {:tools, [{"read_file", %{"path" => "notes.txt"}}]},
               {:text, "A tab is two spaces."},
               {:text, "Still two."}
             ]}
          ]
        )

      on_exit(fn -> FakeOpenAI.stop(stand_in) end)

      overrides = [
        provider: "anthropic",
        base_url: stand_in.url,
        api_key: "test-key",
        model: "claude-opus-5-5",
        thinking_binding: "error"
      ]

      %{session: session} = start_session(context, config_overrides: overrides)
      sid = session.id
      Troupe.subscribe(sid)
      turn(sid, "read the notes")
      :ok = stopped(sid)
      drain()

      {:ok, _} =
        Troupe.resume(sid,
          workspace: context.workspace,
          config_overrides: overrides ++ [auto_approve: true, state_dir: context.state_dir]
        )

      on_exit(fn -> Troupe.stop_session(sid) end)
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "and again")
      await_event(sid, :turn_ended, 10_000)

      requests = FakeOpenAI.requests(stand_in)
      assert length(requests) == 3
      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
      assert Enum.all?(requests, &(&1.binding == "error"))
    end
  end

  # -- helpers ------------------------------------------------------------------

  # The later call's system prompt is the earlier one's, and its messages begin with the
  # earlier one's, compared as the log writes a message.
  defp assert_same_prefix(earlier, later) do
    assert later.system == earlier.system
    assert later.system_tail == earlier.system_tail
    sent = Enum.map(earlier.messages, &Message.to_json/1)
    assert Enum.map(Enum.take(later.messages, length(sent)), &Message.to_json/1) == sent
  end

  defp witness_event(seq, type, data) do
    %Event{
      seq: seq,
      type: type,
      agent: ["root"],
      data: data,
      actor: Event.Actor.system(),
      ts: "2026-01-01T00:00:00.000000Z"
    }
  end

  defp kill_root(sid) do
    agent = Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
    await_event(sid, :agent_restarted)
  end

  defp await_started(sid, mark) do
    receive do
      {:troupe_event, ^sid,
       %Event{type: "tool_call_started", data: %{"args" => %{"mark" => ^mark}}}} ->
        :ok
    after
      5_000 -> flunk("the #{mark} call did not start")
    end
  end

  defp await_reply(sid, text) do
    receive do
      {:troupe_event, ^sid, %Event{type: "llm_response", data: %{"message" => message}}} ->
        if Message.text(Message.from_json(message)) == text, do: :ok, else: await_reply(sid, text)
    after
      10_000 -> flunk("no reply #{inspect(text)}")
    end
  end

  # What a stopped session left in this mailbox, so a wait after the resume is the resumed
  # session's.
  defp drain do
    receive do
      {:troupe_event, _sid, _event} -> drain()
    after
      0 -> :ok
    end
  end

  # `stop_session/1` returns before `Registry` has noticed the exit (see GoalTest).
  defp stopped(session_id) do
    :ok = Troupe.stop_session(session_id)
    wait_for_release(session_id, 200)
  end

  defp wait_for_release(_session_id, 0), do: :ok

  defp wait_for_release(session_id, attempts) do
    if Registry.whereis({:session, session_id}) || Registry.whereis({:log, session_id}) do
      Process.sleep(5)
      wait_for_release(session_id, attempts - 1)
    else
      :ok
    end
  end

  defp two_turns(context, overrides) do
    %{session: session, fake: fake} =
      start_session(context, steps: @steps, config_overrides: overrides)

    sid = session.id
    Troupe.subscribe(sid)
    turn(sid, "write the list")
    turn(sid, "carry on")
    {sid, Fake.requests(fake)}
  end

  defp turn(sid, text) do
    Troupe.send_input(sid, text)
    await_state(sid, [:idle], 10_000)
  end

  # The text a request's message at `index` carries beyond what the person typed: the
  # turn's own block.
  defp turn_context(request, index), do: request.messages |> Enum.at(index) |> turn_context_of()

  defp turn_context_of(%Message{role: :user, content: content}) do
    for %Text{text: "<turn_context>" <> _ = text} <- content, into: "", do: text
  end

  defp turn_context_of(%Message{}), do: ""

  # `{system_changed, tools_changed}` per call, `nil` for an agent's first.
  defp changes(sid) do
    for %{data: data} <- events_of_type(sid, :llm_request) do
      case data do
        %{"system_changed" => system, "tools_changed" => tools} -> {system, tools}
        _first -> nil
      end
    end
  end
end
