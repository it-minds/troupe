defmodule Troupe.Bench.LiveScenarios do
  @moduledoc """
  The scenarios `troupe bench --live` runs against a real model (Decision 773), in the
  order the report lists them.

  The offline suite's scenarios are about the harness's shape, and a script drives them;
  these are small tasks a model has to do itself, each with an outcome a script checks
  afterwards whoever answered: a file written with given content, a failing test fixed,
  a question delegated and its answer used, a tool that always fails recovered from.
  What each shows is whether the work got done on this provider and model, and what it
  cost, in time and in money. A check beside the outcome says the work was done the way
  the scenario is about (delegated, not read directly; the test fixed, not edited).
  """

  alias Troupe.Bench.Scenario

  @doc "Every live scenario, in report order."
  @spec all() :: [Scenario.t()]
  def all, do: [write_file(), fix_test(), delegate(), recover()]

  # -- a file with given content ----------------------------------------------------

  # `scripts/live-check task`'s run: the smallest turn that does something.
  defp write_file do
    %Scenario{
      name: "write_file",
      title: "write a file with given content",
      prompt: """
      Create a file named hello.txt in the current directory whose only content is the line: troupe bench ok
      Use write_file once and do nothing else. When the file is written, say so in one short sentence and stop.\
      """,
      outcome: {:file, "hello.txt", "troupe bench ok\n"},
      measure: &nothing/1
    }
  end

  # -- a failing test fixed ---------------------------------------------------------

  @calc """
  defmodule Calc do
    @doc "The sum of a list of numbers."
    def sum(numbers), do: Enum.reduce(numbers, 1, &+/2)
  end
  """

  @calc_test """
  Code.require_file("calc.exs", __DIR__)
  ExUnit.start()

  defmodule CalcTest do
    use ExUnit.Case

    test "sums a list of numbers" do
      assert Calc.sum([1, 2, 3]) == 6
      assert Calc.sum([]) == 0
    end
  end
  """

  # An Elixir test, since `elixir` is what this repository's own tests have; on a machine
  # without it on the PATH the scenario is left out before anything is spent.
  defp fix_test do
    %Scenario{
      name: "fix_test",
      title: "a failing test fixed",
      prompt: """
      calc_test.exs fails. Fix calc.exs so that the test passes, and do not change calc_test.exs.
      The test runs with: elixir calc_test.exs
      When it passes, say so in one short sentence.\
      """,
      files: %{"calc.exs" => @calc, "calc_test.exs" => @calc_test},
      outcome: {:command, ["elixir", "calc_test.exs"]},
      measure: &test_kept/1
    }
  end

  defp test_kept(ctx) do
    kept = File.read(Path.join(ctx.workspace, "calc_test.exs")) == {:ok, @calc_test}
    {[], [{"test_kept", "calc_test.exs was left as it was", kept}]}
  end

  # -- a question delegated ---------------------------------------------------------

  # `scripts/live-check delegate`'s run, with the answer used rather than only said.
  defp delegate do
    %Scenario{
      name: "delegate",
      title: "a question delegated and its answer used",
      prompt: """
      The notes/ directory holds a few short text files. Find out what the lighthouse keeper's cat is called.
      Do not read, list or search any file yourself: call the delegate tool exactly once, with agent "explore" and a task asking it to find the cat's name in notes/.
      When it reports back, write the cat's name and nothing else to answer.txt with write_file, then say the name in one sentence.\
      """,
      files: %{
        "notes/harbour.txt" =>
          "The harbour opens at six and closes at dusk. Boats moor on the east quay.\n",
        "notes/keeper.txt" =>
          "The lighthouse keeper is Ines Varga. Her cat is called Pemberton and sleeps by the lamp.\n",
        "notes/supplies.txt" => "Oil, wicks and biscuits arrive every second Tuesday.\n"
      },
      outcome: {:file, "answer.txt", "Pemberton\n"},
      measure: &delegated/1
    }
  end

  defp delegated(ctx) do
    delegated =
      Enum.any?(
        ctx.events,
        &(&1.type == "tool_call_started" and &1.agent == ["root"] and
            &1.data["name"] == "delegate")
      )

    {[], [{"delegated", "the root agent called delegate", delegated}]}
  end

  # -- a tool that always fails ------------------------------------------------------

  # The file the prompt names is never there, so every read of it fails, however often it
  # is tried; the way out is the default the prompt gives.
  defp recover do
    %Scenario{
      name: "recover",
      title: "a tool that always fails, recovered from",
      prompt: """
      Read settings/port.txt with read_file to find the port the service listens on. If it cannot be read, the port is 8080.
      Write the port and nothing else to port.txt with write_file, then say which port you wrote.\
      """,
      files: %{"settings/README.txt" => "The service's settings.\n"},
      outcome: {:file, "port.txt", "8080\n"},
      measure: &failed_and_went_on/1
    }
  end

  defp failed_and_went_on(ctx) do
    failed =
      Enum.any?(
        ctx.events,
        &(&1.type == "tool_call_completed" and &1.data["name"] == "read_file" and
            &1.data["ok"] == false)
      )

    {[], [{"failed", "read_file failed, as it always does", failed}]}
  end

  defp nothing(_ctx), do: {[], []}
end
