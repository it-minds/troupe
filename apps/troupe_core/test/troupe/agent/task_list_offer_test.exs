defmodule Troupe.Agent.TaskListOfferTest do
  @moduledoc """
  When an agent is offered the task list (Decision 793). A profile with every tool, as
  `build`, has `todo_write` and `todo_read` while there is a list and once its turn has
  made ten model calls; one that names them, as `plan`, on every call. Long work still
  gets its list, and the clients theirs: the `todo_updated` a write logs.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Todo

  @tools ~w(todo_write todo_read)

  setup context do
    for n <- 1..10, do: write_file(context, "notes/#{n}.txt", "note #{n}\n")
    :ok
  end

  test "a turn is offered the list from its eleventh call, and the next turn starts again",
       context do
    reads = Enum.map(1..10, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]})

    %{session: session, fake: fake} =
      start(context, steps: reads ++ [{:text, "read them"}, {:text, "hello"}])

    turn(session, "read the notes")
    turn(session, "and now?")

    assert offers(fake) == List.duplicate(false, 10) ++ [true, false]
  end

  test "the list written once offered is logged for the clients, and stays offered", context do
    reads = Enum.map(1..10, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]})
    items = [%{"content" => "read the rest", "status" => "in_progress"}]

    %{session: session, fake: fake} =
      start(context,
        steps: reads ++ [{:tools, [{"todo_write", %{"items" => items}}]}, {:text, "listed"}]
      )

    turn(session, "read the notes")
    turn(session, "and now?")

    assert offers(fake) == List.duplicate(false, 10) ++ [true, true, true]

    assert [%{data: %{"items" => [%{"content" => "read the rest", "status" => "in_progress"}]}}] =
             events_of_type(session.id, :todo_updated)

    assert [%Todo{content: "read the rest"}] = Troupe.snapshot(session.id).todos
  end

  test "a call to it unoffered runs, and the list it writes keeps it offered", context do
    items = [%{"content" => "one thing", "status" => "in_progress"}]

    %{session: session, fake: fake} =
      start(context,
        steps: [{:tools, [{"todo_write", %{"items" => items}}]}, {:text, "ok"}, {:text, "again"}]
      )

    turn(session, "go")
    turn(session, "go on")

    assert offers(fake) == [false, true, true]
    assert [_written] = events_of_type(session.id, :todo_updated)
  end

  test "a list a person added in the TUI offers it", context do
    %{session: session, fake: fake} = start(context, steps: [{:text, "seen"}])

    Troupe.send_input(session.id, Todo.Edit.add("check the logs"), :tui_todo_edit)
    await_state(session.id, [:idle])

    assert offers(fake) == [true]
  end

  test "plan, which names the list's tools, has them on every call", context do
    %{session: session, fake: fake} =
      start(context, agent: "plan", steps: [{:text, "a plan"}])

    turn(session, "plan it")

    assert offers(fake) == [true]
  end

  # The model answering from `steps`, and this process told of what the session does.
  defp start(context, opts) do
    %{session: session} = started = start_session(context, opts)
    Troupe.subscribe(session.id)
    started
  end

  defp turn(session, text) do
    Troupe.send_input(session.id, text)
    await_event(session.id, :turn_ended, 10_000)
  end

  # For each request the model was sent, whether it offered both of the list's tools, and
  # neither otherwise.
  defp offers(fake) do
    Enum.map(Fake.requests(fake), fn request ->
      case Enum.filter(request.tools, &(&1.name in @tools)) do
        [] -> false
        [_, _] -> true
      end
    end)
  end
end
