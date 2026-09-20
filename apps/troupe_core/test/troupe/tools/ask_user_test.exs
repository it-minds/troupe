defmodule Troupe.Tools.AskUserTest do
  @moduledoc """
  `ask_user` hands a decision to a person (Decision 651): the question is a durable
  event, the tool waits, the answer over the wire is its result, and nobody there means
  an error the model can act on rather than a wait.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Questions
  alias Troupe.Tools.AskUser

  test "the agent asks, a person answers, and the answer is what the tool returns", context do
    %{session: session} =
      start_session(context,
        steps: [
          {:tools,
           [
             {"ask_user",
              %{
                "question" => "Which colour?",
                "options" => ["red", %{"label" => "blue", "description" => "the calm one"}, ""],
                "multiple" => false
              }}
           ]},
          {:text_and_tools, "Blue it is.", [{"finish", %{"summary" => "picked"}}]}
        ]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "pick a colour")

    assert_receive {:troupe_event, ^sid, %Event{type: "question_asked", data: asked}}, 5_000
    assert asked["question"] == "Which colour?"
    assert asked["multiple"] == false

    assert asked["options"] == [
             %{"label" => "red", "description" => nil},
             %{"label" => "blue", "description" => "the calm one"}
           ]

    assert [%{call_id: call_id}] = Questions.pending(sid)
    assert call_id == asked["call_id"]

    :ok = Troupe.answer(sid, call_id, "blue")

    assert_receive {:troupe_event, ^sid, %Event{type: "question_answered", data: answered}}, 5_000
    assert answered["call_id"] == call_id
    assert answered["text"] == "blue"

    assert_receive {:troupe_event, ^sid, %Event{type: "tool_call_completed", data: completed}}, 5_000
    assert completed["name"] == "ask_user"
    assert completed["ok"] == true
    assert (completed["result"] || completed["content"]) =~ "blue"

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 5_000
    assert Questions.pending(sid) == []
  end

  test "an unattended session answers at once that nobody is there", context do
    %{session: session} =
      start_session(context,
        config_overrides: [approvals: :deny],
        steps: [
          {:tools, [{"ask_user", %{"question" => "Ship it?"}}]},
          {:text_and_tools, "Deciding alone.", [{"finish", %{"summary" => "decided"}}]}
        ]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")

    assert_receive {:troupe_event, ^sid, %Event{type: "question_asked"}}, 5_000
    assert_receive {:troupe_event, ^sid, %Event{type: "tool_call_completed", data: completed}}, 5_000
    assert completed["ok"] == false
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 5_000
  end

  test "normalize coerces what models send" do
    assert %{question: "Q", options: [], multiple: false} = AskUser.normalize(%{"question" => " Q "})

    assert %{options: options, multiple: true} =
             AskUser.normalize(%{
               "question" => "Q",
               "multiple" => "true",
               "options" => [
                 "  a\n b ",
                 %{"name" => "c", "detail" => "  d  "},
                 %{"value" => 3},
                 "a b",
                 nil,
                 %{}
               ]
             })

    assert options == [
             %{label: "a b", description: nil},
             %{label: "c", description: "d"},
             %{label: "3", description: nil}
           ]

    many = AskUser.normalize(%{"question" => "Q", "options" => Enum.map(1..20, &"o#{&1}")})
    assert length(many.options) == AskUser.max_options()
  end
end
