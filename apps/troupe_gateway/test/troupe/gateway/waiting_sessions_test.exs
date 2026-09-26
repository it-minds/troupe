defmodule Troupe.Gateway.WaitingSessionsTest do
  @moduledoc """
  A session waiting on an approval says so in the daemon's `session.list`, the way a
  plane's row does (#145).

  The desktop's inbox is a listing: it shows the sessions whose row counts an approval
  open. A plane's row has carried `pending_approvals`, and `status: "waiting"` while one
  is open, since the worker began reporting them. The daemon's rows carried neither, so in
  local mode a session waiting on its person never reached the inbox. The count keeps the
  rule every other reader keeps (#142): an approval ends with its decision, with its
  call's `tool_call_completed`, or with a cancel of the agent that asked or of one above
  it.

  A dormant session is listed from its log, so that half is held to logs real sessions
  wrote against the scripted model (`test/fixtures/approvals/`): cancelled mid-wait, timed
  out, asked by a subagent the cancel took down, decided, and `open`, which stops while
  the approval still waits.

  A session waiting on a question is waiting on its person as surely, and its rows said
  `pending_approvals: 0`, so it never reached the inbox either (#172). They count
  `pending_questions` beside it now, by the rules a question ends by (#162), and are held
  to `test/fixtures/questions/` the same way.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Paths

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))
  @questions Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "questions"]))

  @ada "ada@example.test"
  @counted ~w(state status pending_approvals pending_questions)

  test "a running session is listed as waiting while its approval is open, and not once a cancel ends it",
       context do
    %{session: session} =
      start_session(context,
        steps: [{:tools, [{"needs_approval", %{"note" => "wait for me"}}]}, {:text, "never"}],
        config: [auto_approve: false]
      )

    client = attach(context, @ada)
    {:ok, _} = Client.call(client, "input.send", command(session.id, %{"text" => "ask me"}))

    assert %{"state" => "active", "status" => "waiting", "pending_approvals" => 1} =
             eventually(fn -> listed(client, session.id, &(&1["pending_approvals"] == 1)) end)

    {:ok, _} = Client.call(client, "turn.cancel", command(session.id, %{}))

    assert %{"status" => "idle", "pending_approvals" => 0} =
             eventually(fn -> listed(client, session.id, &(&1["pending_approvals"] == 0)) end)
  end

  test "a running session is listed as waiting while its question is open, and not once a cancel ends it",
       context do
    ask = %{"question" => "Which colour?", "options" => ["red", "blue"]}

    %{session: session} =
      start_session(context, steps: [{:tools, [{"ask_user", ask}]}, {:text, "never"}])

    client = attach(context, @ada)
    {:ok, _} = Client.call(client, "input.send", command(session.id, %{"text" => "ask me"}))

    waiting = %{
      "state" => "active",
      "status" => "waiting",
      "pending_approvals" => 0,
      "pending_questions" => 1
    }

    assert waiting == eventually(fn -> row(client, session.id, &(&1["status"] == "waiting")) end)

    # `fleet.get` answers with the same rows.
    {:ok, %{"sessions" => fleet}} = Client.call(client, "fleet.get")
    assert waiting == fleet |> Enum.find(&(&1["id"] == session.id)) |> Map.take(@counted)

    {:ok, _} = Client.call(client, "turn.cancel", command(session.id, %{}))

    assert %{"status" => "idle", "pending_approvals" => 0, "pending_questions" => 0} =
             eventually(fn -> row(client, session.id, &(&1["pending_questions"] == 0)) end)
  end

  test "a dormant session is listed from its log, waiting only on an approval still open",
       context do
    for name <- ~w(open decided cancelled timed_out subagent_cancelled) do
      dir = Paths.session_dir(context.workspace, "recorded-" <> name, context.state_dir)
      File.mkdir_p!(dir)
      File.cp!(Path.join(@recorded, name <> ".jsonl"), Path.join(dir, "events.jsonl"))
    end

    client = attach(context, @ada)
    {:ok, %{"sessions" => sessions}} = Client.call(client, "session.list")

    rows =
      for %{"id" => "recorded-" <> name} = row <- sessions,
          into: %{},
          do: {name, Map.take(row, @counted)}

    assert rows["open"] == dormant("waiting", 1, 0)

    for name <- ~w(decided cancelled timed_out subagent_cancelled) do
      assert rows[name] == dormant("idle", 0, 0), "#{name}: #{inspect(rows[name])}"
    end
  end

  # The same rule for a question (#162), from `test/fixtures/questions/`. A budget question
  # a cancel ended is still owed, and waits again once the next message asks it again. The
  # root's alone count, as for an approval: a subagent the cancel took down owes nothing.
  test "a dormant session is listed as waiting on a question only while it still waits",
       context do
    names = ~w(open answered timed_out cancelled subagent_cancelled failures_cancelled
               failures_unattended budget_cancelled budget_asked_again budget_unattended)

    for name <- names do
      dir = Paths.session_dir(context.workspace, "asked-" <> name, context.state_dir)
      File.mkdir_p!(dir)
      File.cp!(Path.join(@questions, name <> ".jsonl"), Path.join(dir, "events.jsonl"))
    end

    client = attach(context, @ada)
    {:ok, %{"sessions" => sessions}} = Client.call(client, "session.list")

    rows =
      for %{"id" => "asked-" <> name} = row <- sessions,
          into: %{},
          do: {name, Map.take(row, @counted)}

    for name <- ~w(open budget_asked_again) do
      assert rows[name] == dormant("waiting", 0, 1), "#{name}: #{inspect(rows[name])}"
    end

    for name <- names -- ~w(open budget_asked_again budget_unattended) do
      assert rows[name] == dormant("idle", 0, 0), "#{name}: #{inspect(rows[name])}"
    end

    # Denied with nobody to ask, the budget ends the agent.
    assert rows["budget_unattended"] == dormant("done", 0, 0)
  end

  defp dormant(status, approvals, questions) do
    %{
      "state" => "dormant",
      "status" => status,
      "pending_approvals" => approvals,
      "pending_questions" => questions
    }
  end

  defp command(session_id, params) do
    Map.merge(%{"command_id" => Client.command_id(), "session_id" => session_id}, params)
  end

  # The session's row, once it says what `predicate` asks for.
  defp listed(client, session_id, predicate) do
    {:ok, %{"sessions" => sessions}} = Client.call(client, "session.list")

    case Enum.find(sessions, &(&1["id"] == session_id)) do
      nil -> nil
      row -> if predicate.(row), do: row
    end
  end

  # Only the columns an inbox reads.
  defp row(client, session_id, predicate) do
    case listed(client, session_id, predicate) do
      nil -> nil
      row -> Map.take(row, @counted)
    end
  end
end
