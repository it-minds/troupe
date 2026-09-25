defmodule Troupe.Worker.ApprovalStatusTest do
  @moduledoc """
  What the plane is told about approvals, read from logs real sessions wrote (#142).

  An approval ends with its decision, with its call — a cancel closes each call it stops
  with a `tool_call_completed`, and so does a tool that timed out waiting — or with a
  cancel on the agent that asked or on one above it, which takes a subagent down without
  a word from it. The plane lists `waiting` sessions and their `pending_approvals` as a
  review queue, so one a cancel left open is a session somebody is sent to answer and
  cannot.

  The logs are `test/fixtures/approvals/`, written by sessions against the scripted
  model; `open` stops while the approval is still waiting.
  """

  use ExUnit.Case, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Worker.Session.Manager
  alias Troupe.Worker.Sessions

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))

  setup do
    start_supervised!(Sessions)
    :ok
  end

  test "an approval cancelled mid-wait, timed out, or asked by a cancelled subagent is not pending" do
    reported = replay(~w(cancelled timed_out subagent_cancelled))

    for {name, report} <- reported do
      assert %{"status" => "idle", "pending_approvals" => 0} = report, name
    end
  end

  test "a decided approval is not pending, and one nobody has answered is waiting" do
    reported = replay(~w(decided open))

    assert %{"status" => "idle", "pending_approvals" => 0} = reported["decided"]
    assert %{"status" => "waiting", "pending_approvals" => 1} = reported["open"]
  end

  # One manager per log, with no tree behind it and marked active so that it reports: the
  # lifecycle is a fold over the events a session publishes, and those are what each one
  # is sent here, in the order the session wrote them. The answer is the last report each
  # one made once they have all gone quiet, since a report is debounced.
  defp replay(names) do
    test = self()

    for name <- names do
      session_id = "recorded-" <> name
      opts = [session_id: session_id, report: &send(test, {:report, &1})]
      manager = start_supervised!(Supervisor.child_spec({Manager, opts}, id: name))
      :sys.replace_state(manager, &%{&1 | status: :active})

      for event <- recorded(name), do: send(manager, {:troupe_event, session_id, event})
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

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
  end
end
