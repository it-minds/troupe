defmodule Troupe.RecordedApprovalsTest do
  @moduledoc """
  What a window shows as waiting on its person, folded from logs real sessions wrote
  (#145).

  An approval ends with its decision, with its call — a cancel closes each call it stops
  with a `tool_call_completed`, and so does a tool that timed out waiting — or with a
  cancel of the agent that asked or of one above it, which takes a subagent down without
  a word from it (#142). One the window kept after that is an approval nobody can answer,
  and it holds the window in `needs_input`.

  The logs are `test/fixtures/approvals/` at the repository's root, written by sessions
  against the scripted model and read here the way a daemon's worker hands them over:
  through `Troupe.Remote.Translate`. `open` stops while the approval still waits.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))

  test "an approval cancelled mid-wait, timed out, or asked by a cancelled subagent is not pending" do
    for name <- ~w(cancelled timed_out subagent_cancelled) do
      assert pending(name) == [], "#{name} still has #{inspect(pending(name))}"
    end
  end

  test "a decided approval is not pending, and one nobody has answered is" do
    assert pending("decided") == []
    assert [%{kind: :approval, call_id: "call_4", agent_path: "root"}] = pending("open")
  end

  # A call re-run after the daemon restarted asks for its approval again under the same id.
  test "an approval asked again after a restart, under the same id, is drawn once" do
    events = recorded("open")
    asked = Enum.find(events, &(&1["type"] == "approval_requested"))
    again = %{asked | "seq" => Enum.max(Enum.map(events, & &1["seq"])) + 1}

    assert [%{kind: :approval, call_id: "call_4"}] = fold(events ++ [again])
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
