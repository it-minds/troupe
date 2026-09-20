defmodule Troupe.RemoteTranslateTest do
  @moduledoc """
  The worker's events, as PROTOCOL.md §4 spells them, become the local events the
  TUI folds. Pure: no fake, no socket — the shapes are the ones the live worker
  sends (Decision 98).
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate

  @moduletag :remote

  defp durable(type, data, extra \\ %{}) do
    Map.merge(
      %{
        "seq" => 7,
        "prev_hash" => "sha256:abc",
        "ts" => "2026-09-19T15:39:27.000Z",
        "actor" => %{"kind" => "user", "subject" => "idp|martin", "display_name" => "Martin"},
        "agent" => ["root"],
        "type" => type,
        "v" => 1,
        "data" => data
      },
      extra
    )
  end

  defp translate(event) do
    {events, _memory} =
      Translate.durable("s-1", event, Translate.remember(Translate.memory(), "root"))

    events
  end

  test "an agent path arrives as a list and becomes this client's spelling" do
    [event] = translate(durable("user_input", %{"source" => "user", "text" => "hello"}))
    assert event.agent_path == "root"

    [child] =
      translate(durable("llm_request", %{"model" => "m"}, %{"agent" => ["root", "explore#1"]}))

    assert child.agent_path == "root/explore#1"
    assert Translate.root_of(%{"agent" => ["root", "explore#1"]}) == "root"
  end

  test "input events: user_input, input_queued and input_accepted" do
    [input] = translate(durable("user_input", %{"source" => "user", "text" => "fix it"}))
    assert input.type == :input
    assert input.data.content == "fix it"
    assert input.data.actor == "Martin"
    assert input.seq == 7

    [queued] =
      translate(
        durable("input_queued", %{"command_id" => "cmd_1", "author" => "m", "text" => "later"})
      )

    assert queued.type == :input
    assert queued.data.command_id == "cmd_1"

    [accepted] = translate(durable("input_accepted", %{"command_id" => "cmd_1", "author" => "m"}))
    assert accepted.type == :input_accepted
    assert accepted.data.command_id == "cmd_1"
    assert Translate.command_id(durable("input_accepted", %{"command_id" => "cmd_1"})) == "cmd_1"
  end

  test "llm_response carries the whole message; its text and tool uses are kept" do
    data = %{
      "message" => %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Hello."},
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "read_file",
            "input" => %{"path" => "a"}
          }
        ]
      },
      "usage" => %{"input_tokens" => 12, "output_tokens" => 3},
      "stop_reason" => "tool_use",
      "model" => "code-default"
    }

    [message] = translate(durable("llm_response", data))
    assert message.type == :assistant_message

    # the tool use is not in the message: `tool_call_started` is what draws it
    assert [%{type: :text, text: "Hello."}] = message.data.content

    assert message.data.usage.input == 12
    assert message.data.usage.output == 3
    assert message.data.model == "code-default"
  end

  test "tool calls, approvals and todos in the worker's spelling" do
    [started] =
      translate(
        durable("tool_call_started", %{
          "call_id" => "c1",
          "name" => "shell",
          "args" => %{"cmd" => "ls"}
        })
      )

    assert started.type == :tool_started
    assert started.data == %{call_id: "c1", name: "shell", input: %{"cmd" => "ls"}}

    [completed] =
      translate(
        durable("tool_call_completed", %{
          "call_id" => "c1",
          "name" => "shell",
          "ok" => true,
          "content" => "a\nb"
        })
      )

    assert completed.type == :tool_call_completed
    assert completed.data.ok
    assert completed.data.content == "a\nb"

    [asked] =
      translate(
        durable("approval_requested", %{
          "call_id" => "c2",
          "tool" => "shell",
          "args" => %{},
          "agent_path" => ["root"]
        })
      )

    assert asked.type == :approval_requested
    assert asked.data.name == "shell"

    [decided] =
      translate(
        durable("approval_decided", %{
          "call_id" => "c2",
          "tool" => "shell",
          "decision" => "allow",
          "actor" => "m"
        })
      )

    assert decided.type == :approval_answered
    assert decided.data.decision == :allow

    [todos] =
      translate(
        durable("todo_updated", %{
          "items" => [%{"id" => "t1", "content" => "write tests", "status" => "in_progress"}],
          "source" => "model"
        })
      )

    assert todos.type == :todo_updated
    assert [%{text: "write tests", status: :in_progress, id: "t1"}] = todos.data.items
  end

  test "lifecycle events become state and notes" do
    assert [%{type: :agent_state, data: %{to: :thinking}}] =
             translate(durable("llm_request", %{"model" => "m"}))

    assert [
             %{type: :agent_state, data: %{to: :done}},
             %{type: :remote_note, data: %{text: "done: all green"}}
           ] =
             translate(durable("agent_done", %{"reason" => "finished", "summary" => "all green"}))

    assert [%{type: :remote_note}, %{type: :remote_status, data: %{state: :active}}] =
             translate(durable("session_activated", %{"epoch" => 2, "pod" => "troupe-w-dev-0"}))

    assert [%{type: :remote_note}, %{type: :remote_status, data: %{state: :dormant}}] =
             translate(durable("session_dormant", %{"last_seq" => 40}))

    assert [
             %{type: :remote_note, data: %{text: "woken"}},
             %{type: :agent_state, data: %{to: :thinking}}
           ] =
             translate(durable("agent_woken", %{"from" => "finished", "source" => "user"}))

    assert [] = translate(durable("tool_results", %{"results" => []}))
  end

  test "ephemerals: a delta's kind decides what it is, and agent_state is the agent's word" do
    memory = Translate.memory()

    {[delta], _} =
      Translate.ephemeral(
        "s-1",
        %{
          "ephemeral" => true,
          "type" => "llm_delta",
          "agent" => ["root"],
          "data" => %{"kind" => "text", "text" => "Let me "}
        },
        memory
      )

    assert delta.type == :llm_delta
    assert delta.data == %{text: "Let me "}

    {[thinking], _} =
      Translate.ephemeral(
        "s-1",
        %{
          "ephemeral" => true,
          "type" => "llm_delta",
          "agent" => ["root"],
          "data" => %{"kind" => "reasoning", "text" => "hmm"}
        },
        memory
      )

    assert thinking.data == %{text: "hmm", reasoning: true}

    {[state], _} =
      Translate.ephemeral(
        "s-1",
        %{
          "ephemeral" => true,
          "type" => "agent_state",
          "agent" => ["root"],
          "data" => %{"state" => "acting", "profile" => "build"}
        },
        memory
      )

    assert state.type == :agent_state
    assert state.data == %{to: :acting}

    {[], _} =
      Translate.ephemeral(
        "s-1",
        %{"ephemeral" => true, "type" => "summary_diff", "agent" => ["root"], "data" => %{}},
        memory
      )
  end

  test "a question asked and answered: the menu the model draws, and what clears it" do
    [asked] =
      translate(
        durable("question_asked", %{
          "call_id" => "q1",
          "agent_path" => ["root"],
          "question" => "Which colour?",
          "options" => [
            %{"label" => "red", "description" => nil},
            %{"label" => "blue", "description" => "calm"},
            "green"
          ],
          "multiple" => true
        })
      )

    assert asked.type == :question_asked
    assert asked.data.call_id == "q1"
    assert asked.data.question == "Which colour?"
    assert asked.data.multiple == true

    assert asked.data.options == [
             %{label: "red", description: nil},
             %{label: "blue", description: "calm"},
             %{label: "green", description: nil}
           ]

    [answered] = translate(durable("question_answered", %{"call_id" => "q1", "text" => "blue"}))
    assert answered.type == :question_answered
    assert answered.data == %{call_id: "q1", text: "blue"}
  end
end
