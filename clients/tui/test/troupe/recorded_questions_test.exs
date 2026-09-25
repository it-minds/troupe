defmodule Troupe.RecordedQuestionsTest do
  @moduledoc """
  What a window shows as a question waiting on its person, folded from logs real
  sessions wrote (#162).

  A question ends as an approval does: with its answer, with its call — a cancel closes
  each call it stops with a `tool_call_completed`, and so does a tool that timed out
  waiting — or with a cancel of the agent that asked or of one above it. The budget's
  and the failure guard's question have no call of their own, and also end with the
  harness's `budget_ask_answered` or `tool_failures_ask_answered`, which is all there is
  when nobody is there to ask.

  The logs are `test/fixtures/questions/` at the repository's root, written by sessions
  against the scripted model and read here the way a daemon's worker hands them over:
  through `Troupe.Remote.Translate`. `open` stops while the question still waits.
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

  defp pending(name) do
    {events, _memory} =
      Enum.flat_map_reduce(recorded(name), Translate.memory(), &Translate.durable("s-1", &1, &2))

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
