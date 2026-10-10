defmodule Troupe.Watch.WatchBranchTest do
  @moduledoc """
  Where a watch trigger goes (Decision 844): a branch of the watching session, in its
  checkout, on `quick` for an `AI!` and on `answer` for an `AI?` (TUI Decision 67), never
  a turn of the session's own agent; and a write that branch makes asks, whatever the
  session's `auto_approve` says, unless `watch_auto_approve` is on.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Session.{Approvals, Watcher}

  @calc "defmodule Calc do\n  def answer, do: 0\nend\n"
  @marked "defmodule Calc do\n  # make this 42 AI!\n  def answer, do: 0\nend\n"
  @edit {"edit_file",
         %{
           "path" => "lib/calc.ex",
           "old_string" => "  # make this 42 AI!\n  def answer, do: 0",
           "new_string" => "  def answer, do: 42"
         }}

  # The trigger the session wrote, and the branch it names, stopped when the test ends.
  defp triggered(session) do
    event = await_event(session.id, :watch_triggered, 10_000)
    child = event.data["session_id"]
    if child, do: on_exit(fn -> Troupe.stop_session(child) end)
    {event.data, child}
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false, []] and tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      other ->
        other
    end
  end

  defp watching(context, overrides, steps) do
    start_session(context,
      config_overrides: [watch: true, watch_debounce_ms: 80] ++ overrides,
      steps: steps
    )
  end

  test "an AI! comment starts a quick branch in the checkout, and the session's own agent gets nothing",
       context do
    write_file(context, "lib/calc.ex", @calc)
    %{session: session} = watching(context, [], [{:tools, [@edit]}, {:text, "Made it 42."}])
    Troupe.subscribe(session.id)

    write_file(context, "lib/calc.ex", @marked)
    {data, child} = triggered(session)

    assert data["agent"] == "quick"
    assert data["mode"] == "change"
    assert [%{"file" => "lib/calc.ex", "line" => 2, "comment" => comment}] = data["markers"]
    assert comment =~ "make this 42"

    # A branch of this session, in the checkout the comment was written in.
    row = Troupe.get_session(child)
    assert row.parent == session.id
    assert row.workspace == session.workspace.root_real
    assert row.profile == "quick"

    # The session's own agent was told nothing; the branch was, as a watch input.
    assert events_of_type(session.id, "user_input") == []
    [input] = eventually(fn -> events_of_type(child, "user_input") end)
    assert input.data["source"] == "watch"
    assert input.data["text"] =~ "lib/calc.ex:2"

    # Its write asks, though the session auto-approves.
    [asked] = eventually(fn -> events_of_type(child, "approval_requested") end)
    assert asked.data["tool"] == "edit_file"
    assert read_file(context, "lib/calc.ex") =~ "AI!"

    Approvals.decide(child, asked.data["call_id"], :allow)
    eventually(fn -> read_file(context, "lib/calc.ex") =~ "def answer, do: 42" end)
    refute read_file(context, "lib/calc.ex") =~ "AI!"

    # The branch works in the same files and does not watch them itself.
    refute Watcher.enabled?(child)
  end

  test "an AI? comment starts an answer branch whose turn runs under the plan permission set",
       context do
    write_file(context, "lib/thing.ex", "defmodule Thing do\n  def n, do: 0\nend\n")

    %{session: session} =
      watching(context, [watch_auto_approve: true], [
        # The model tries to edit anyway; the permission set in force for this turn must
        # stop it before the tool runs, though watch writes are auto-approved here.
        {:tools, [{"write_file", %{"path" => "lib/thing.ex", "content" => "clobbered"}}]},
        {:text, "It is zero because nothing sets it."}
      ])

    Troupe.subscribe(session.id)

    write_file(
      context,
      "lib/thing.ex",
      "defmodule Thing do\n  # why is this zero? AI?\n  def n, do: 0\nend\n"
    )

    {data, child} = triggered(session)
    assert data["agent"] == "answer"
    assert data["mode"] == "question"
    assert Troupe.get_session(child).profile == "answer"

    [attempt] = eventually(fn -> events_of_type(child, "tool_call_completed") end)
    refute attempt.data["ok"]
    assert attempt.data["content"] =~ "not available in the current profile"
    assert read_file(context, "lib/thing.ex") =~ "def n, do: 0"

    [input] = events_of_type(child, "user_input")
    assert input.data["source"] == "watch"
    assert input.data["text"] =~ "AI? comment"
    assert events_of_type(session.id, "user_input") == []
  end

  # The plan permission set narrows whatever `answer` is: a workspace's that may write
  # still may not on a question's turn, and keeps its own model.
  test "an AI? turn cannot write even on an answer redefined to", context do
    write_file(context, ".troupe/agents/answer.md", """
    ---
    description: answers, and would write
    mode: primary
    model: cheap
    tools: [read_file, write_file, finish]
    ---
    Answer it.
    """)

    write_file(context, "lib/thing.ex", "defmodule Thing do\n  def n, do: 0\nend\n")

    %{session: session} =
      watching(context, [watch_auto_approve: true], [
        {:tools, [{"write_file", %{"path" => "lib/thing.ex", "content" => "clobbered"}}]},
        {:text, "No."}
      ])

    Troupe.subscribe(session.id)

    write_file(
      context,
      "lib/thing.ex",
      "defmodule Thing do\n  # why zero? AI?\n  def n, do: 0\nend\n"
    )

    {_data, child} = triggered(session)

    [attempt] = eventually(fn -> events_of_type(child, "tool_call_completed") end)
    refute attempt.data["ok"]
    assert read_file(context, "lib/thing.ex") =~ "def n, do: 0"
  end

  test "with watch_auto_approve on, the branch's write runs without asking", context do
    write_file(context, "lib/calc.ex", @calc)

    %{session: session} =
      watching(context, [watch_auto_approve: true], [{:tools, [@edit]}, {:text, "Made it 42."}])

    Troupe.subscribe(session.id)
    write_file(context, "lib/calc.ex", @marked)
    {_data, child} = triggered(session)

    eventually(fn -> read_file(context, "lib/calc.ex") =~ "def answer, do: 42" end)
    assert read_file(context, "lib/calc.ex") =~ "def answer, do: 42"
    assert events_of_type(child, "approval_requested") == []
  end

  # The editor saves again while the branch's write waits for the person: that is the same
  # request, not a second branch.
  test "a comment is not sent again while its branch is at work, and is once it has ended",
       context do
    write_file(context, "lib/calc.ex", @calc)
    %{session: session} = watching(context, [], [{:tools, [@edit]}, {:text, "Made it 42."}])
    Troupe.subscribe(session.id)

    path = write_file(context, "lib/calc.ex", @marked)
    {_data, child} = triggered(session)
    [asked] = eventually(fn -> events_of_type(child, "approval_requested") end)

    write_file(context, "lib/calc.ex", @marked <> "# saved again\n")
    :ok = Watcher.scan_now(session.id, [path])
    assert length(events_of_type(session.id, "watch_triggered")) == 1

    Approvals.decide(child, asked.data["call_id"], :allow)
    watcher = Registry.watcher_pid(session.id)
    assert eventually(fn -> :sys.get_state(watcher).working == %{} end)

    write_file(context, "lib/calc.ex", @marked)
    :ok = Watcher.scan_now(session.id, [path])
    {_data, again} = triggered(session)
    assert again != child
  end

  test "an agent's own auto on a write is held for a branch a comment started", context do
    # A trusted workspace's `quick` that would edit unasked (Decision 825 lets it): a file
    # any process can write must not be able to start that.
    write_file(context, ".troupe/agents/quick.md", """
    ---
    description: quick, but it edits unasked
    mode: primary
    tools: [read_file, edit_file, finish]
    permissions:
      edit_file: auto
    ---
    Make the change.
    """)

    write_file(context, "lib/calc.ex", @calc)

    %{session: session} =
      watching(context, [trusted_workspaces: [context.workspace]], [
        {:tools, [@edit]},
        {:text, "Made it 42."}
      ])

    Troupe.subscribe(session.id)
    write_file(context, "lib/calc.ex", @marked)
    {_data, child} = triggered(session)

    [asked] = eventually(fn -> events_of_type(child, "approval_requested") end)
    assert asked.data["tool"] == "edit_file"
    assert read_file(context, "lib/calc.ex") =~ "AI!"
  end
end
