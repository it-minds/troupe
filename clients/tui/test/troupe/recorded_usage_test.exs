defmodule Troupe.RecordedUsageTest do
  @moduledoc """
  What a window says it has spent, folded from logs real sessions wrote (#158).

  The worker reports a reply's usage the way `Troupe.LLM.Usage` writes it — `input_tokens`,
  `output_tokens`, `cache_read`, `cache_write` — and `Troupe.Remote.Translate` hands the
  model its own shape. The two once disagreed on the names, so every turn folded as
  `↑0 ↓0`. Each side's own test used a map that side made up; this one crosses the
  boundary with the events a session wrote.

  The logs are `test/fixtures/approvals/` at the repository's root (the same ones
  `Troupe.RecordedApprovalsTest` reads), written against the scripted model.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))

  test "a window and its agent count what each reply reported" do
    # Two replies: 100 tokens in and 10 out, then 100 in and 1 out.
    [window] = windows("decided")

    assert window.usage == %{input: 200, output: 11, cache_read: 0, cache_write: 0}
    assert window.agents["root"].usage == window.usage
    assert Model.tokens(window) == "↑200 ↓11"
    assert Model.total_tokens(window) == 211
  end

  test "a subagent's replies are its own, and the window's too" do
    [window] = windows("subagent_cancelled")

    assert %{input: 100, output: 15} = window.agents["root"].usage
    assert %{input: 100, output: 10} = window.agents["root/general#1"].usage
    assert Model.tokens(window) == "↑200 ↓25"
  end

  defp windows(name) do
    {events, _memory} =
      Enum.flat_map_reduce(recorded(name), Translate.memory(), &Translate.durable("s-1", &1, &2))

    "s-1" |> Model.rebuild("/w", events) |> Model.windows()
  end

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
