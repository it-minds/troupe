defmodule Troupe.BenchCLITest do
  @moduledoc """
  `troupe bench` (issue #390, root Decision 772, TUI Decision 140): the offline suite of
  the harness this binary carries, printed as a table or as JSON, and an exit status a
  script can act on. `async: false`: while it runs, the bench points `TROUPE_CONFIG_HOME`
  and `TROUPE_STATE_HOME` at its own directories, which no other test may see.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI
  alias Troupe.CLI.Bench

  test "troupe bench parses, with --json, and --live is a reserved flag" do
    assert {:ok, %{mode: :bench, json: false, live: false}} = CLI.parse(["bench"])
    assert {:ok, %{mode: :bench, json: true}} = CLI.parse(["bench", "--json"])
    assert {:ok, %{mode: :bench, live: true}} = CLI.parse(["bench", "--live"])
    assert CLI.usage() =~ "troupe bench"
  end

  test "troupe bench prints a row a measure and exits 0 within every budget" do
    {:ok, args} = CLI.parse(["bench"])
    out = capture_io(fn -> assert Bench.run(args) == 0 end)

    assert out =~ "| scenario | measure | value | budget | |"
    for scenario <- Troupe.Bench.scenarios(), do: assert(out =~ "| #{scenario.name} | ")
    assert out =~ "| tool_calls | model calls in the turn | 31 calls | 31 | ok |"

    assert out =~
             ~r/offline: 5 scenarios, every measure within its budget\.\nThe suite took [\d.]+ s\.\n\z/
  end

  test "troupe bench --json prints the report and nothing else" do
    {:ok, args} = CLI.parse(["bench", "--json"])
    out = capture_io(fn -> assert Bench.run(args) == 0 end)

    assert {:ok, %{"schema" => 1, "mode" => "offline", "passed" => true, "scenarios" => [_ | _]}} =
             Jason.decode(out)
  end

  test "troupe bench --live refuses, for now, and runs nothing" do
    {:ok, args} = CLI.parse(["bench", "--live"])

    err =
      capture_io(:stderr, fn ->
        assert capture_io(fn -> assert Bench.run(args) == 2 end) == ""
      end)

    assert err =~ "troupe bench --live: not yet"
  end
end
