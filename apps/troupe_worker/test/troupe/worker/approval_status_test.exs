defmodule Troupe.Worker.ApprovalStatusTest do
  @moduledoc """
  What the plane is told about approvals and questions, read from logs real sessions
  wrote (#142, #172).

  An approval ends with its decision, with its call — a cancel closes each call it stops
  with a `tool_call_completed`, and so does a tool that timed out waiting — or with a
  cancel on the agent that asked or on one above it, which takes a subagent down without
  a word from it. The plane lists `waiting` sessions and their `pending_approvals` as a
  review queue, so one a cancel left open is a session somebody is sent to answer and
  cannot.

  A question waits on a person as surely, and was reported as nothing at all: the
  `pending_questions` beside the count of approvals ends by the same rules, or with its
  answer, which for the budget's and the failure guard's question the harness gives
  itself when nobody is there to ask (#162).

  The logs are `test/fixtures/approvals/` and `test/fixtures/questions/`, written by
  sessions against the scripted model; each `open` stops while it is still waiting.
  """

  use ExUnit.Case, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Worker.Session.Manager
  alias Troupe.Worker.Sessions

  @fixtures Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures"]))

  setup do
    start_supervised!(Sessions)
    :ok
  end

  test "an approval cancelled mid-wait, timed out, or asked by a cancelled subagent is not pending" do
    reported = replay("approvals", ~w(cancelled timed_out subagent_cancelled))

    for {name, report} <- reported do
      assert %{"status" => "idle", "pending_approvals" => 0} = report, name
    end
  end

  test "a decided approval is not pending, and one nobody has answered is waiting" do
    reported = replay("approvals", ~w(decided open))

    assert %{"status" => "idle", "pending_approvals" => 0} = reported["decided"]
    assert %{"status" => "waiting", "pending_approvals" => 1} = reported["open"]
    assert %{"pending_questions" => 0} = reported["open"]
  end

  test "a question nobody has answered is waiting, and so is the gate's asked again after a cancel" do
    reported = replay("questions", ~w(open budget_asked_again))

    for {name, report} <- reported do
      assert %{"status" => "waiting", "pending_questions" => 1, "pending_approvals" => 0} =
               report,
             name
    end
  end

  test "a question answered, cancelled, timed out, or asked by a cancelled subagent is not pending" do
    names = ~w(answered cancelled timed_out subagent_cancelled failures_cancelled
               failures_unattended budget_cancelled budget_unattended)

    reported = replay("questions", names)
    assert Map.keys(reported) |> Enum.sort() == Enum.sort(names)

    for {name, report} <- reported do
      assert %{"status" => "idle", "pending_questions" => 0} = report, name
    end
  end

  # One manager per log, with no tree behind it and marked active so that it reports: the
  # lifecycle is a fold over the events a session publishes, and those are what each one
  # is sent here, in the order the session wrote them. The answer is the last report each
  # one made once they have all gone quiet, since a report is debounced.
  defp replay(dir, names) do
    test = self()

    for name <- names do
      session_id = "recorded-" <> name
      opts = [session_id: session_id, report: &send(test, {:report, &1})]
      manager = start_supervised!(Supervisor.child_spec({Manager, opts}, id: name))
      :sys.replace_state(manager, &%{&1 | status: :active})

      for event <- recorded(dir, name), do: send(manager, {:troupe_event, session_id, event})
    end

    last_reports(%{})
    |> Map.new(fn {"recorded-" <> name, report} -> {name, report} end)
  end

  defp last_reports(acc) do
    receive do
      {:report, %{"type" => "session.status", "session_id" => id} = report} ->
        last_reports(Map.put(acc, id, report))
    after
      1_000 -> acc
    end
  end

  defp recorded(dir, name) do
    [@fixtures, dir, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
  end
end
