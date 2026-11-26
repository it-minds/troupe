defmodule Troupe.RecordedProposalsTest do
  @moduledoc """
  The terminal's lines for what the harness proposed (root #1208), against the logs under
  `test/fixtures/proposals/` at the repository's root, read through `Troupe.Remote.Translate`
  as a worker hands them over: the proposal once as a line naming its question, and its
  answer once as a line naming the report.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "proposals"]))

  defp notes(name) do
    {events, _memory} =
      @recorded
      |> Path.join(name <> ".jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.flat_map_reduce(Translate.memory(), &Translate.durable("s-1", &1, &2))

    for %{type: :remote_note, data: %{text: text}} <- events, do: text
  end

  test "open: the question, why, and how to answer it, once" do
    assert [line] = Enum.filter(notes("open"), &(&1 =~ "Troupe asks"))

    assert line =~
             "Troupe asks: Rerun this report every Monday? It was built from live data (1 query from the shell)"

    assert line =~ "/proposal yes turns it on"
  end

  test "accepted and never: the answer's line names the report and who answered" do
    assert Enum.any?(
             notes("accepted"),
             &(&1 ==
                 "Ada turned on a rerun of \"Weekly numbers\" as the trigger rerun-weekly-numbers of reports; each run asks to be reviewed.")
           )

    assert Enum.any?(notes("never"), &(&1 =~ "said never for rerunning \"Weekly numbers\""))
  end
end
