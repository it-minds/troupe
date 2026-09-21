defmodule Troupe.QuestionClientTest do
  @moduledoc """
  `ask_user` from the client's side (Decision 106): the question arrives as the menu the
  model draws, the answer goes back as `question.answer`, and the agent goes on with it.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  @script [
    {:tools,
     [
       {"ask_user",
        %{
          "question" => "Which colour?",
          "options" => ["red", %{"label" => "blue", "description" => "the calm one"}]
        }}
     ]},
    {:text, "Blue it is."},
    {:finish, "picked blue"}
  ]

  test "the question arrives with its options, and the answer is the tool's result" do
    {sid, _, _ws} = start_session!(script: @script)
    say!(sid, "pick a colour")

    asked = await_event("root", :question_asked)
    assert asked.data.question == "Which colour?"
    assert asked.data.multiple == false

    assert asked.data.options == [
             %{label: "red", description: nil},
             %{label: "blue", description: "the calm one"}
           ]

    :ok = Client.answer(sid, asked.data.call_id, "blue")
    answered = await_event("root", :question_answered)
    assert answered.data.call_id == asked.data.call_id
    assert answered.data.text == "blue"

    completed = await_event("root", :tool_call_completed)
    assert completed.data.ok
    assert completed.data.content =~ "blue"
    await_done()
  end

  test "the TUI draws the menu and a digit answers it" do
    {sid, _, _ws} = start_session!(script: @script)
    {pid, session} = start_tui(sid)

    type(pid, "pick a colour")
    press(pid, "enter")

    await_event("root", :question_asked)
    press(pid, "1")
    eventually(fn -> screen_text(pid, session) =~ "Which colour?" end)
    eventually(fn -> screen_text(pid, session) =~ "blue" end)

    # The second option, by its number.
    press(pid, "2")
    answered = await_event("root", :question_answered)
    assert answered.data.text == "blue"
    await_done()
    eventually(fn -> screen_text(pid, session) =~ "Blue it is." end)
  end
end
