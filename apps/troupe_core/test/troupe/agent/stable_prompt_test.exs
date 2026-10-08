defmodule Troupe.Agent.StablePromptTest do
  @moduledoc """
  Issue #465's second option (Decision 815): with `system_prompt: stable` the system prompt
  is the same on every call of a session, and what changes between turns (the task list,
  the instruction files and the brief, the goal) goes with the turn instead, in a block
  of the turn's own message that stays where it was put. By default it is in the system
  prompt, as Decisions 792 and 798 have it, and changes it between turns.

  The log says, per call, whether the system prompt and the tools changed since the
  agent's call before, which is what `Troupe.Bench.Prefix` counts.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Message, Text}

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

  test "by default the task list a turn left changes the system prompt the next turn begins with",
       context do
    {sid, [first, second, third, fourth]} = two_turns(context, [])

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

  # -- helpers ------------------------------------------------------------------

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
  defp turn_context(request, index) do
    %Message{role: :user, content: content} = Enum.at(request.messages, index)

    content
    |> Enum.drop(1)
    |> Enum.map_join("\n", fn %Text{text: text} -> text end)
  end

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
