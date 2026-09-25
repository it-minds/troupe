defmodule Troupe.RecordedQuestionsTest do
  @moduledoc """
  What a window shows as a question waiting on its person, folded from logs real
  sessions wrote (#162).

  A question ends as an approval does: with its answer, with its call — a cancel closes
  each call it stops with a `tool_call_completed`, and so does a tool that timed out
  waiting — or with a cancel of the agent that asked or of one above it. The budget's
  and the failure guard's question have no call of their own, and also end with the
  harness's `budget_ask_answered` or `tool_failures_ask_answered`, which is all there is
  when nobody is there to ask. One of those a cancel ended is still owed, and the next
  message makes the gate ask it again under the same id.

  The logs are `test/fixtures/questions/` at the repository's root, written by sessions
  against the scripted model and read here the way a daemon's worker hands them over:
  through `Troupe.Remote.Translate`. `open` stops while the question still waits, and
  `budget_asked_again` goes on from `budget_cancelled` to the question asked again.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "questions"]))

  test "a question whose tool timed out, or that a cancel reached, is not pending" do
    for name <- ~w(timed_out cancelled subagent_cancelled failures_cancelled budget_cancelled) do
      assert pending(name) == [], "#{name} still has #{inspect(pending(name))}"
    end
  end

  test "a question the harness answered itself, with nobody to ask, is not pending" do
    for name <- ~w(failures_unattended budget_unattended) do
      assert pending(name) == [], "#{name} still has #{inspect(pending(name))}"
    end
  end

  test "an answered question is not pending, and one nobody has answered is" do
    assert pending("answered") == []
    assert [%{kind: :question, call_id: "call_16", agent_path: "root"}] = pending("open")
  end

  test "the budget question a cancel ended is pending again once the gate asks it again" do
    assert [%{kind: :budget, call_id: "budget-1", agent_path: "root", detail: "turns 1/1 (100%)"}] =
             pending("budget_asked_again")
  end

  # A session that comes back asks the question it slept on again, with no cancel between:
  # the same log without its cancel.
  test "the budget question asked again with no cancel between is drawn once" do
    events = Enum.reject(recorded("budget_asked_again"), &(&1["type"] == "cancelled"))
    assert [%{kind: :budget, call_id: "budget-1"}] = fold(events)
  end

  # A daemon that comes back re-runs the call its agent was waiting in, and the call asks
  # its question again under the same id: one question to answer, drawn once.
  test "a question asked again after a restart, under the same id, is drawn once" do
    events = recorded("open")
    asked = Enum.find(events, &(&1["type"] == "question_asked"))
    again = %{asked | "seq" => Enum.max(Enum.map(events, & &1["seq"])) + 1}

    assert [%{kind: :question, call_id: "call_16"}] = fold(events ++ [again])
  end

  defp pending(name), do: fold(recorded(name))

  defp fold(recorded) do
    {events, _memory} =
      Enum.flat_map_reduce(recorded, Translate.memory(), &Translate.durable("s-1", &1, &2))

    "s-1"
    |> Model.rebuild("/w", events)
    |> Model.windows()
    |> Enum.flat_map(& &1.pending)
  end

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
