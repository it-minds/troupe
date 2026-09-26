defmodule Troupe.Agent.InputTest do
  @moduledoc """
  Every event an input writes names the send it came from (issue #181).

  A client that draws a line the moment it is typed has to know, when the durable copy
  comes back, that it is the same line: `input_queued` and `input_accepted` always said
  so, and `user_input`, the one that carries the text, did not, so the TUI drew every
  typed line twice.
  """

  use Troupe.SessionCase, async: true

  test "a line sent to an idle agent is written with the command id it was sent with", context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])
    Troupe.subscribe(session.id)

    Troupe.send_input(session.id, "hello", :user, nil, command_id: "c-idle")
    await_event(session.id, :turn_ended)

    assert [%{data: %{"command_id" => "c-idle"}}] = events_of_type(session.id, :input_accepted)

    assert [%{data: %{"command_id" => "c-idle", "source" => "user", "text" => "hello"}}] =
             events_of_type(session.id, :user_input)
  end

  test "a line sent mid-turn names its send when it is queued and when it is taken", context do
    # The model takes a while to answer the first line, so the second arrives mid-turn.
    %{session: session} =
      start_session(context, steps: [{:text, "one"}, {:text, "two"}], delay_ms: 300)

    Troupe.subscribe(session.id)

    Troupe.send_input(session.id, "first", :user, nil, command_id: "c-first")
    await_event(session.id, :llm_request)
    Troupe.send_input(session.id, "second", :user, nil, command_id: "c-second")
    # One turn for each line: the second is taken when the first turn ends.
    await_event(session.id, :turn_ended, 10_000)
    await_event(session.id, :turn_ended, 10_000)

    assert [%{data: %{"command_id" => "c-second", "text" => "second"}}] =
             events_of_type(session.id, :input_queued)

    assert session.id |> events_of_type(:input_accepted) |> Enum.map(& &1.data["command_id"]) ==
             ["c-first", "c-second"]

    assert session.id
           |> events_of_type(:user_input)
           |> Enum.map(&{&1.data["command_id"], &1.data["text"]}) ==
             [{"c-first", "first"}, {"c-second", "second"}]
  end

  test "an input sent without a command id is written with the one it was given", context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])
    Troupe.subscribe(session.id)

    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [%{data: %{"command_id" => id}}] = events_of_type(session.id, :input_accepted)
    assert is_binary(id)
    assert [%{data: %{"command_id" => ^id}}] = events_of_type(session.id, :user_input)
  end
end
