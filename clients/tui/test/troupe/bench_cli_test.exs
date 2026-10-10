Code.require_file("../../../../apps/troupe_core/test/support/fake_openai.exs", __DIR__)

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
  alias Troupe.Test.FakeOpenAI

  @key "sk-bench-not-a-real-key-7731"

  test "troupe bench parses, with --json, and --live with its own flags" do
    assert {:ok, %{mode: :bench, json: false, live: false}} = CLI.parse(["bench"])
    assert {:ok, %{mode: :bench, json: true, json_path: nil}} = CLI.parse(["bench", "--json"])
    assert {:ok, %{mode: :bench, live: true}} = CLI.parse(["bench", "--live"])
    assert CLI.usage() =~ "troupe bench"

    # `--json` and `--compare` take the word after them, unless it is a flag.
    assert {:ok,
            %{
              live: true,
              repeat: 3,
              model: "gw/m",
              yes: true,
              json: true,
              json_path: "a.json",
              md: "a.md"
            }} =
             CLI.parse(~w(bench --live --repeat 3 --model gw/m --yes --json a.json --md a.md))

    assert {:ok, %{suite: "standard", scenario: "fix_test,large_log", keep: "runs", live: true}} =
             CLI.parse(~w(bench --live --suite standard --scenario fix_test,large_log --keep runs))

    assert {:ok, %{json: true, json_path: nil, live: true}} = CLI.parse(~w(bench --json --live))
    assert {:ok, %{compare: true, ref: nil}} = CLI.parse(~w(bench --compare))
    assert {:ok, %{compare: true, ref: "0.8.1-beta"}} = CLI.parse(~w(bench --compare 0.8.1-beta))

    assert {:ok, %{compare: true, ref: nil, json_path: "b.json"}} =
             CLI.parse(~w(bench --compare --json b.json))

    # Only after `bench`: `--json` elsewhere is a switch and nothing more.
    assert {:ok, %{mode: :config_explain, json_path: nil}} = CLI.parse(~w(config --json))
  end

  test "--repeat, --model, --yes, --suite, --scenario and --keep are refused without --live" do
    for argv <- [~w(bench --repeat 2), ~w(bench --suite standard), ~w(bench --keep runs)] do
      {:ok, args} = CLI.parse(argv)

      err =
        capture_io(:stderr, fn ->
          assert capture_io(fn -> assert Bench.run(args) == 2 end) == ""
        end)

      assert err =~ "--repeat, --model, --yes, --suite, --scenario and --keep go with --live"
    end
  end

  test "troupe bench prints a row a measure and exits 0 within every budget" do
    {:ok, args} = CLI.parse(["bench"])
    out = capture_io(fn -> assert Bench.run(args) == 0 end)

    assert out =~ "| scenario | measure | value | budget | |"
    for scenario <- Troupe.Bench.scenarios(), do: assert(out =~ "| #{scenario.name} | ")
    assert out =~ "| tool_calls | model calls in the turn | 31 calls | 31 | ok |"

    assert out =~
             ~r/offline: 10 scenarios, every measure within its budget\.\nThe suite took [\d.]+ s\.\n\z/
  end

  test "troupe bench --json prints the report and nothing else" do
    {:ok, args} = CLI.parse(["bench", "--json"])
    out = capture_io(fn -> assert Bench.run(args) == 0 end)

    assert {:ok, %{"schema" => 1, "mode" => "offline", "passed" => true, "scenarios" => [_ | _]}} =
             Jason.decode(out)
  end

  describe "troupe bench --live, against a stand-in for your provider" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      fake = FakeOpenAI.start()
      on_exit(fn -> FakeOpenAI.stop(fake) end)
      %{state: state} = person(dir, fake)
      %{fake: fake, dir: dir, state: state}
    end

    test "runs the live suite once you say yes to its cap", %{fake: fake} do
      {:ok, args} = CLI.parse(["bench", "--live"])

      {status, out, err} = run_bench(args, "y\n", ask: &at_terminal/1)

      assert status == 0, err
      assert err =~ ~r/at most \$[\d.]+ in all/
      assert out =~ "| write_file | runs that succeeded | 1.0 |"
      assert FakeOpenAI.requests(fake) != []
    end

    test "prints the cap and runs nothing without a yes", %{fake: fake} do
      {:ok, args} = CLI.parse(["bench", "--live"])

      for answer <- ["", "n\n", "\n"] do
        {status, out, err} = run_bench(args, answer, ask: &at_terminal/1)

        assert status == 2
        assert out == ""
        assert err =~ "troupe bench --live: 4 scenarios, 1 run each, against openai/standin-1."
        assert err =~ "so this costs at most $3.84 in all."
        assert err =~ "Spend up to $3.84 on openai/standin-1? [y/N] "
        assert err =~ "Nothing was run."
      end

      assert FakeOpenAI.requests(fake) == []
    end

    test "asks only at a terminal: from a script it runs nothing without --yes", %{fake: fake} do
      {:ok, args} = CLI.parse(["bench", "--live"])

      {status, out, err} = run_bench(args, "y\n")

      assert status == 2
      assert out == ""
      assert err =~ "so this costs at most $3.84 in all."
      refute err =~ "[y/N]"
      assert err =~ "Nothing was run: there is no terminal to ask in. Pass --yes to run it."
      assert FakeOpenAI.requests(fake) == []
    end

    test "--yes --repeat 2 --json FILE --md FILE: the report, the table, the history, and never the key",
         %{fake: fake, dir: dir, state: state} do
      json = Path.join(dir, "live.json")
      md = Path.join(dir, "live.md")
      {:ok, args} = CLI.parse(~w(bench --live --yes --repeat 2 --json #{json} --md #{md}))

      {status, out, err} = run_bench(args, "")

      assert status == 0, err
      refute err =~ "[y/N]"

      report = json |> File.read!() |> Jason.decode!()

      assert %{"mode" => "live", "model" => "openai/standin-1", "repeat" => 2, "passed" => true} =
               report

      assert length(report["scenarios"]) == 4

      for entry <- report["scenarios"], run <- entry["runs"] do
        assert run["succeeded"]

        assert Enum.all?(
                 run["calls"],
                 &(is_integer(&1["latency_ms"]) and is_integer(&1["cost_micros"]))
               )
      end

      assert Enum.all?(report["scenarios"], &(length(&1["runs"]) == 2))

      # The table on standard output and in the file; a line a run on standard error.
      assert out =~ "| fix_test | outcome: `elixir calc_test.exs` exits 0 | 2 of 2 | ok |"
      assert out =~ ~r/every run succeeded\.\nThe live bench took [\d.]+ s\.\n\z/
      assert File.read!(md) =~ "| delegate | the root agent called delegate (2 of 2) | yes | ok |"
      assert err =~ "recover 2/2: succeeded, "

      history = Path.join([state, "bench", "results.jsonl"])
      assert history |> File.read!() |> String.split("\n", trim: true) |> length() == 8

      # The key went to the provider and nowhere else.
      assert Enum.all?(FakeOpenAI.requests(fake), &(&1.authorization == "Bearer " <> @key))

      for text <- [out, err, File.read!(json), File.read!(md), File.read!(history)],
          do: refute(text =~ @key)
    end

    test "--suite standard --keep DIR: ten tasks, a summary, and every run's directory kept",
         %{dir: dir} do
      json = Path.join(dir, "standard.json")
      keep = Path.join(dir, "runs")
      {:ok, args} = CLI.parse(~w(bench --live --yes --suite standard --keep #{keep} --json #{json}))

      {status, out, err} = run_bench(args, "")

      assert status == 0, err
      assert err =~ "The standard suite: write_file, fix_test, delegate, recover, rename_symbol,"
      assert err =~ "Each run's workspace and session log are kept under #{keep}."

      report = json |> File.read!() |> Jason.decode!()
      assert %{"live_suite" => "standard", "summary" => %{"runs" => 10, "succeeded" => 10}} = report
      assert File.dir?(Path.join(report["kept_in"], "large_log-1"))
      assert out =~ "| 10 scenarios together | |"
    end

    test "--scenario runs the ones named, and refuses one that is not there", %{fake: fake} do
      {:ok, args} = CLI.parse(~w(bench --live --yes --scenario answer_only,write_file))
      {status, out, _err} = run_bench(args, "")

      assert status == 0
      assert out =~ "| write_file | runs that succeeded | 1.0 |"
      assert out =~ "| answer_only | the reply is 391 (1 of 1) | yes | ok |"

      requests = length(FakeOpenAI.requests(fake))
      {:ok, args} = CLI.parse(~w(bench --live --yes --scenario fix_test,nope))
      {status, out, err} = run_bench(args, "")

      assert status == 2
      assert out == ""
      assert err =~ "troupe bench: no live scenario is called nope"
      assert length(FakeOpenAI.requests(fake)) == requests
    end

    test "--compare reads the history: nothing yet, then the last bench against the one before" do
      {:ok, compare} = CLI.parse(~w(bench --compare))

      {status, _out, err} = run_bench(compare, "")
      assert status == 2
      assert err =~ "no live bench is recorded"

      {:ok, live} = CLI.parse(~w(bench --live --yes))
      assert {0, _out, _err} = run_bench(live, "")
      assert {0, _out, _err} = run_bench(live, "")

      {status, out, _err} = run_bench(compare, "")
      assert status == 0
      assert out =~ "| scenario | measure | then | now | change |"
      assert out =~ "| write_file | runs that succeeded | 1.0 | 1.0 | 0.0 |"
      assert out =~ ~r/Now: troupe bench \S+ against openai\/standin-1, /
    end
  end

  # The person whose provider the live suite uses: a config file naming the stand-in, with
  # a key, and a state directory, in place of the suite's, put back afterwards.
  defp person(dir, fake) do
    config = Path.join(dir, "config")
    state = Path.join(dir, "state")
    File.mkdir_p!(config)
    File.mkdir_p!(state)

    File.write!(Path.join(config, "config.yaml"), """
    version: 1
    provider: openai
    base_url: #{fake.url}
    api_key: #{@key}
    models:
      default: #{FakeOpenAI.model()}
      prices:
        #{FakeOpenAI.model()}: {input: 3, output: 15}
    """)

    previous = Map.new(~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME), &{&1, System.get_env(&1)})
    System.put_env("TROUPE_CONFIG_HOME", config)
    System.put_env("TROUPE_STATE_HOME", state)

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    %{config: config, state: state}
  end

  # The person at a terminal, as a test plays them: the question beside the plan, the
  # answer from the input.
  defp at_terminal(question) do
    IO.write(:stderr, question)
    IO.gets("")
  end

  defp run_bench(args, input, opts \\ []) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io([input: input, capture_prompt: false], fn ->
            send(parent, {:status, Bench.run(args, opts)})
          end)

        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end
end
