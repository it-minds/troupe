Code.require_file("../support/fake_openai.exs", __DIR__)

defmodule Troupe.BenchLiveTest do
  @moduledoc """
  `troupe bench --live` (issue #390, Decision 773), against a stand-in for an
  OpenAI-compatible provider on a loopback port (`test/support/fake_openai.exs`), which
  answers each scenario as it asks, with a delay and usage: nothing here calls a model.

  It says what it will spend before it starts, from the person's provider settings and
  never their key; each run has its own directories, its limits, a deadline and a share of
  the cap; the report fills schema 1's live fields (latency, time to first token, tokens,
  cost, retries, each tool's time); every run goes into the history, which `compare/1`
  reads.

  `async: false`: a run points `TROUPE_CONFIG_HOME` and `TROUPE_STATE_HOME` at its own
  directories, which no other test may see, and counts every provider retry in the VM.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Troupe.Prefix, as: PrefixTask
  alias Troupe.Bench
  alias Troupe.Bench.{History, Live, LiveScenarios, Scenario}
  alias Troupe.Protocol.Event
  alias Troupe.Test.FakeOpenAI

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @key "sk-bench-not-a-real-key-7731"
  @price %{"input" => 3, "output" => 15}

  # The person's configuration: the stand-in as an OpenAI-compatible provider, with a key
  # and a price for its model.
  defp person(fake, extra \\ []) do
    Troupe.Config.load(
      nil,
      [
        provider: "openai",
        base_url: fake.url,
        api_key: @key,
        model: FakeOpenAI.model(),
        prices: %{FakeOpenAI.model() => @price}
      ] ++ extra
    )
  end

  defp start_fake(opts \\ []) do
    fake = FakeOpenAI.start(opts)
    on_exit(fn -> FakeOpenAI.stop(fake) end)
    fake
  end

  defp only(names), do: Enum.filter(LiveScenarios.all(), &(&1.name in names))

  describe "the plan" do
    test "is a run's limits at the model's price, times the runs, said before anything starts" do
      fake = start_fake()
      assert {:ok, plan} = Bench.plan(config: person(fake), repeat: 2, history: nil)

      assert plan.model == "openai/standin-1"
      assert Enum.map(plan.scenarios, & &1.name) == ~w(write_file fix_test delegate recover)

      # 200,000 tokens in at $3 a million and 24,000 out at $15: $0.96 a run, eight runs.
      assert plan.run_cap_micros == 960_000
      assert plan.cap_micros == 960_000 * 8

      text = Bench.describe_plan(plan)
      assert text =~ "4 scenarios, 2 runs each, against openai/standin-1."
      assert text =~ "may make 12 model calls, send 200,000 tokens and receive 24,000, in 240 s."
      assert text =~ "a run costs at most $0.96, so this costs at most $7.68 in all."
      assert Bench.question(plan) == "Spend up to $7.68 on openai/standin-1? [y/N] "

      # The key goes to each run, and nowhere a person or a log could read it.
      assert {:api_key, @key} in plan.settings
      refute text =~ @key
      refute inspect(plan) =~ @key
      assert FakeOpenAI.requests(fake) == []
    end

    test "a model nothing prices is capped in tokens, and the question says so" do
      fake = start_fake()
      config = %{person(fake) | prices: %{}}
      assert {:ok, plan} = Bench.plan(config: config, history: nil)

      assert plan.cap_micros == nil

      assert Bench.describe_plan(plan) =~
               "said in tokens: at most 800,000 sent and 96,000 received in all."

      assert Bench.question(plan) =~ "with no price to hold it to?"
    end

    test "a provider with no key is refused before anything" do
      config =
        Troupe.Config.load(nil,
          provider: "anthropic",
          base_url: "https://gateway.example.test",
          model: "m"
        )

      assert {:error, why} = Bench.plan(config: config, history: nil)
      assert why =~ "has no key: `troupe config` sets one up"
    end

    test "a scenario checked by a program this machine lacks is left out, and says why" do
      fake = start_fake()

      missing = %Scenario{
        name: "needs_it",
        title: "t",
        prompt: "p",
        outcome: {:command, ["troupe-bench-no-such-program", "x"]},
        measure: fn _ctx -> {[], []} end
      }

      assert {:ok, plan} =
               Bench.plan(
                 config: person(fake),
                 scenarios: [missing | only(["write_file"])],
                 history: nil
               )

      assert Enum.map(plan.scenarios, & &1.name) == ["write_file"]
      assert [%{"name" => "needs_it", "why" => why}] = plan.skipped
      assert why =~ "`troupe-bench-no-such-program`, which is not on the PATH"
      assert plan.cap_micros == 960_000
    end
  end

  describe "a run" do
    test "each scenario, twice, against the stand-in: the report fills the live fields", %{
      tmp_dir: dir
    } do
      fake = start_fake(first_token_ms: 30, done_ms: 120)
      history = Path.join(dir, "results.jsonl")
      {:ok, plan} = Bench.plan(config: person(fake), repeat: 2, history: history)

      lines = :ets.new(:progress, [:public, :bag])
      report = Bench.live(plan, progress: &:ets.insert(lines, {&1}))

      assert Bench.passed?(report), Bench.markdown(report)

      assert %{"schema" => 1, "mode" => "live", "model" => "openai/standin-1", "repeat" => 2} =
               report

      assert Enum.map(report["scenarios"], & &1["name"]) ==
               ~w(write_file fix_test delegate recover)

      for entry <- report["scenarios"] do
        assert %{"passed" => true, "error" => nil, "outcome" => %{"held" => 2, "passed" => true}} =
                 entry

        assert [_, _] = entry["runs"]
        assert metric(entry, "success_rate") == 1.0

        for run <- entry["runs"] do
          assert %{"succeeded" => true, "error" => nil, "outcome" => true, "retries" => 0} = run
          assert run["model_calls"] == length(run["calls"])
          assert run["wall_ms"] > 0

          for call <- run["calls"] do
            # The stand-in's first chunk comes after 30 ms and its last after 120.
            assert call["first_token_ms"] >= 30
            assert call["latency_ms"] >= 120
            assert call["first_token_ms"] < call["latency_ms"]
            assert call["input_tokens"] > 0 and call["output_tokens"] > 0
            # Priced by models.prices, since a stream carries no cost header.
            assert is_integer(call["cost_micros"]) and call["cost_micros"] > 0
            # What the prompt was made of, as its llm_request says (Decision 769).
            assert call["prompt_bytes"] ==
                     call["system_bytes"] + call["tool_definition_bytes"] +
                       call["conversation_bytes"]

            assert call["system_bytes"] > 0 and is_integer(call["tool_result_bytes"])
            refute call["summariser"]
          end

          assert run["cost_micros"] == run["calls"] |> Enum.map(& &1["cost_micros"]) |> Enum.sum()
          # After the first answer half of each prompt was served from the cache.
          assert run["cached_tokens"] > 0
          for tool <- run["tools"], do: assert(is_integer(tool["ms"]))
        end
      end

      delegate = scenario(report, "delegate")
      [run | _] = delegate["runs"]
      assert Enum.any?(run["calls"], &String.starts_with?(&1["agent"], "root/"))
      # The delegation took the explore agent's two calls, at 120 ms each; the stand-in
      # numbers each agent's tool calls from one, so the two agents' ids are the same.
      assert %{"name" => "delegate", "calls" => 1, "failures" => 0, "ms" => ms} =
               tool(run, "delegate")

      assert ms >= 240

      assert %{"label" => "the root agent called delegate (2 of 2)", "passed" => true} =
               hd(delegate["checks"])

      recover = scenario(report, "recover")
      assert %{"calls" => 2, "failures" => 2} = tool(hd(recover["runs"]), "read_file")

      assert Bench.markdown(report) =~ "| write_file | runs that succeeded | 1.0 |  |"

      assert Bench.markdown(report) =~
               "| delegate | outcome: answer.txt holds what was asked for | 2 of 2 | ok |"

      assert Bench.markdown(report) =~
               "live against openai/standin-1: 4 scenarios, 2 runs each, every run succeeded."

      assert {:ok, _decoded} = Jason.decode(Bench.json(report))

      # Every run in the history as it ended, and a progress line for each.
      assert [_, _, _, _, _, _, _, _] = runs = History.read(history)

      assert Enum.all?(
               runs,
               &(&1["bench"] == report["started_at"] and &1["version"] == report["version"])
             )

      assert length(:ets.tab2list(lines)) == 8

      # The key reached the provider, and nothing written down.
      assert Enum.all?(FakeOpenAI.requests(fake), &(&1.authorization == "Bearer " <> @key))
      refute File.read!(history) =~ @key
      refute Bench.json(report) =~ @key
    end

    test "a provider's retries are counted, which the log never sees", %{tmp_dir: _dir} do
      fake = start_fake(errors: 1)

      {:ok, plan} =
        Bench.plan(config: person(fake), scenarios: only(["write_file"]), history: nil)

      report = Bench.live(plan)

      assert [%{"retries" => 1, "succeeded" => true}] = scenario(report, "write_file")["runs"]
      assert [%{status: 500}, %{status: 200} | _] = FakeOpenAI.requests(fake)
    end

    test "a run that has not ended by its wall clock is stopped, and says so" do
      fake = start_fake(done_ms: 5_000)

      {:ok, plan} =
        Bench.plan(
          config: person(fake),
          scenarios: only(["write_file"]),
          limits: [wall_clock_ms: 1_000],
          history: nil
        )

      {micros, report} = :timer.tc(fn -> Bench.live(plan) end)

      assert [%{"succeeded" => false, "error" => error}] = scenario(report, "write_file")["runs"]
      assert error =~ "had not ended 1.3 s after it started, and was stopped"
      assert micros < 5_000_000
      refute Bench.passed?(report)
      assert Bench.markdown(report) =~ "FAILED write_file"
    end

    test "a run that reaches its share of the cap is stopped there" do
      fake = start_fake()

      # A run may send ten tokens: the first call's prompt costs more than that.
      {:ok, plan} =
        Bench.plan(
          config: person(fake),
          scenarios: only(["write_file"]),
          limits: [max_input_tokens: 10, max_output_tokens: 10],
          history: nil
        )

      report = Bench.live(plan)

      assert [%{"succeeded" => false, "error" => error, "model_calls" => 1}] =
               scenario(report, "write_file")["runs"]

      assert error =~ "reached its share of the cap"
      assert length(FakeOpenAI.requests(fake)) == 1
    end
  end

  describe "the history" do
    test "the last bench against the one before, or a version's, or a model's", %{tmp_dir: dir} do
      path = Path.join(dir, "results.jsonl")

      assert {:error, why} = Bench.compare(history: path)
      assert why =~ "no live bench is recorded"

      for {bench, version, model, cost, ok} <- [
            {"2026-10-01T10:00:00Z", "0.8.1-beta", "openai/a", 4_000, true},
            {"2026-10-02T10:00:00Z", "0.8.2-beta", "openai/b", 9_000, false},
            {"2026-10-03T10:00:00Z", "0.8.2-beta", "openai/a", 5_000, true}
          ],
          n <- [1, 2] do
        History.append(path, line(bench, version, model, cost, ok, n))
      end

      File.write!(path, "not a line\n", [:append])

      # Against the last bench before it, which was model b's.
      assert {:ok, table} = Bench.compare(history: path)

      assert table =~
               "| write_file | runs | 2, 0.8.2-beta, openai/b | 2, 0.8.2-beta, openai/a |  |"

      assert table =~ "| write_file | runs that succeeded | 0.0 | 1.0 | +1.0 |"
      assert table =~ "| write_file | median cost | $0.0090 | $0.0050 | -44% |"
      assert table =~ "Now: troupe bench 0.8.2-beta against openai/a, 2026-10-03T10:00:00Z."

      # Against a version, and against a model.
      assert {:ok, table} = Bench.compare(history: path, ref: "0.8.1-beta")
      assert table =~ "| write_file | median cost | $0.0040 | $0.0050 | +25% |"
      assert table =~ "Then: the last runs of 0.8.1-beta before it."

      assert {:ok, table} = Bench.compare(history: path, ref: "openai/b")
      assert table =~ "| write_file | median cost | $0.0090 | $0.0050 | -44% |"

      assert {:ok, table} = Bench.compare(history: path, ref: "0.7.0-beta")
      assert table =~ "| write_file | runs | none earlier | 2, 0.8.2-beta, openai/a |  |"
    end

    # D125: a live bench writes its history under the configured `state_dir`, and the
    # comparison read the default one, so it said nothing was recorded.
    test "is read where the configured state_dir keeps it, where a live bench writes it",
         %{tmp_dir: dir} do
      config_home = Path.join(dir, "config")
      configured = Path.join(dir, "configured-state")
      File.mkdir_p!(config_home)
      File.write!(Path.join(config_home, "config.yaml"), "state_dir: #{configured}\n")

      previous = Map.new(~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME), &{&1, System.get_env(&1)})
      System.put_env("TROUPE_CONFIG_HOME", config_home)
      System.put_env("TROUPE_STATE_HOME", Path.join(dir, "default-state"))

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      for {bench, cost} <- [{"2026-10-01T10:00:00Z", 4_000}, {"2026-10-02T10:00:00Z", 5_000}] do
        History.append(
          History.path(configured),
          line(bench, "0.8.2-beta", "openai/a", cost, true, 1)
        )
      end

      assert {:ok, table} = Bench.compare()
      assert table =~ "| write_file | median cost | $0.0040 | $0.0050 | +25% |"
    end
  end

  # Issue #465's two options against the stand-in as Anthropic (Decision 815): a model that
  # thinks unasked, binds each thinking block to the conversation it was made in and
  # refuses one sent back after that changed, as Claude Opus 5.5 does for an account the
  # check is enforced for; and caches what is marked. `follow_up`'s second turn begins
  # with docs/AGENTS.md among the instruction files, which its first brought in. A stable
  # system prompt is the default since Decision 863; `per_turn` is the prompt as it was.
  describe "issue #465's settings" do
    test "a fresh config: neither follow_up nor task_list changes anything in front of what was sent" do
      fake = start_fake()

      {:ok, plan} =
        Bench.plan(config: anthropic(fake), only: ["follow_up", "task_list"], history: nil)

      refute Bench.describe_plan(plan) =~ "issue #465"

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)

      assert report["experiment"] == %{
               "thinking_binding" => "default",
               "system_prompt" => "stable"
             }

      for name <- ["follow_up", "task_list"] do
        [run] = scenario(report, name)["runs"]

        assert %{"system_changes" => 0, "tools_changes" => 0, "thinking_resent" => 0} =
                 run["prefix"],
               name

        assert run["prefix"]["turn_contexts"] == 2, name
      end

      requests = FakeOpenAI.requests(fake)
      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
      assert Enum.all?(requests, &(&1.beta == nil))
    end

    # Issue #591: `error` is an enforced account's refusal asked for by name, and the API's
    # word on each refusal is on the call's `llm_response`.
    test "with thinking_binding: error, per_turn is refused as an enforced account is, and says why",
         %{tmp_dir: dir} do
      fake = start_fake()
      keep = Path.join(dir, "kept")

      {:ok, plan} =
        Bench.plan(
          config: anthropic(fake, thinking_binding: "error", system_prompt: "per_turn"),
          only: ["follow_up"],
          keep: keep,
          history: nil
        )

      assert Bench.describe_plan(plan) =~
               "With issue #465's settings changed: thinking_binding error, system_prompt per_turn."

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)
      [run] = scenario(report, "follow_up")["runs"]
      # Refused once for the change, and not again: the call sent again without its
      # thinking let the blocks from before the change go from the conversation.
      assert %{"system_changes" => 1, "thinking_resent" => 1} = run["prefix"]

      requests = FakeOpenAI.requests(fake)
      assert [200, 200, 200, 400, 200, 200] = Enum.map(requests, & &1.status)

      # Each request that may hand thinking back asks for the refusal; the call sent again
      # without its thinking has nothing to bind.
      assert Enum.map(requests, & &1.binding) ==
               ["error", "error", "error", "error", nil, "error"]

      # The refusal's header, on the answer the call ended with, and nothing else of it.
      responses =
        keep
        |> Path.join("**/events.jsonl")
        |> Path.wildcard()
        |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n", trim: true)))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["type"] == "llm_response"))

      mismatched = Enum.filter(responses, & &1["data"]["prefix_mismatch"])
      assert length(mismatched) == 1
      assert Enum.all?(mismatched, & &1["data"]["thinking_resent"])

      assert Enum.uniq(Enum.map(mismatched, & &1["data"]["prefix_mismatch"])) == [
               "kind=system_changed; pattern=system_rerendered; sections=system; changed_validated=system.0"
             ]
    end

    test "with thinking_binding: error and a stable system prompt nothing is refused" do
      fake = start_fake()

      {:ok, plan} =
        Bench.plan(
          config: anthropic(fake, thinking_binding: "error"),
          only: ["follow_up", "task_list"],
          history: nil
        )

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)
      assert report["summary"]["prefix"]["thinking_resent"] == 0
      assert report["summary"]["prefix"]["system_changes"] == 0

      requests = FakeOpenAI.requests(fake)
      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
      assert Enum.any?(requests, &(&1.binding == "error"))
    end

    test "with system_prompt: per_turn the second turn's first call is refused once and sent again without thinking, and the rest are not",
         %{tmp_dir: dir} do
      fake = start_fake()
      keep = Path.join(dir, "kept")

      {:ok, plan} =
        Bench.plan(
          config: anthropic(fake, system_prompt: "per_turn"),
          only: ["follow_up"],
          keep: keep,
          history: nil
        )

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)

      assert report["experiment"] == %{
               "thinking_binding" => "default",
               "system_prompt" => "per_turn"
             }

      [run] = scenario(report, "follow_up")["runs"]
      assert run["model_calls"] == 5

      assert %{
               "model_calls" => 5,
               "system_changes" => 1,
               "tools_changes" => 0,
               "inferred" => 0,
               "thinking_resent" => 1,
               "thinking_dropped" => 0,
               "turn_contexts" => 0
             } = run["prefix"]

      assert report["summary"]["prefix"]["thinking_resent"] == 1

      # One refusal, followed by the same call with no thinking in it; the call after it
      # carries only the thinking made since, and is not refused.
      assert [200, 200, 200, 400, 200, 200] =
               Enum.map(FakeOpenAI.requests(fake), & &1.status)

      # The counter over the kept session log says what the run's record says.
      output = capture_io(fn -> PrefixTask.run(["--json", keep]) end)
      assert %{"total" => %{"sessions" => 1} = total} = Jason.decode!(output)
      assert Map.delete(total, "sessions") == run["prefix"]
    end

    test "with thinking_binding: drop_block nothing is refused, and the stale blocks are dropped" do
      fake = start_fake()

      {:ok, plan} =
        Bench.plan(
          config: anthropic(fake, thinking_binding: "drop_block", system_prompt: "per_turn"),
          only: ["follow_up"],
          history: nil
        )

      assert Bench.describe_plan(plan) =~
               "With issue #465's settings changed: thinking_binding drop_block, system_prompt per_turn."

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)

      # The second turn's first call drops the first turn's three blocks, and the
      # conversation lets them go: its second carries only the one the first made, kept.
      [run] = scenario(report, "follow_up")["runs"]

      assert %{
               "system_changes" => 1,
               "thinking_resent" => 0,
               "thinking_dropped" => 3,
               "calls_dropping" => 1
             } = run["prefix"]

      requests = FakeOpenAI.requests(fake)
      assert Enum.all?(requests, &(&1.status == 200))
      assert Enum.all?(requests, &(&1.beta == "thinking-binding-controls-2026-08-01"))
      thinking = Enum.map(requests, & &1.thinking)
      assert thinking == [:kept, :kept, :kept, {:dropped, 3}, :kept]

      assert [nil, nil, nil, "kind=system_changed" <> _, nil] =
               Enum.map(requests, & &1[:mismatch])
    end

    test "with system_prompt: stable nothing changes in front of what was sent, and the cache reads it" do
      runs =
        for system_prompt <- ["per_turn", "stable"], into: %{} do
          fake = start_fake()

          {:ok, plan} =
            Bench.plan(
              config: anthropic(fake, system_prompt: system_prompt),
              only: ["follow_up"],
              history: nil
            )

          report = Bench.live(plan)
          assert Bench.passed?(report), Bench.markdown(report)
          [run] = scenario(report, "follow_up")["runs"]
          {system_prompt, {run, FakeOpenAI.requests(fake)}}
        end

      {stable, requests} = runs["stable"]

      assert %{
               "system_changes" => 0,
               "tools_changes" => 0,
               "thinking_resent" => 0,
               "thinking_dropped" => 0,
               "turn_contexts" => 2
             } = stable["prefix"]

      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
      assert [_one] = requests |> Enum.map(& &1.system) |> Enum.uniq()

      # Every call after the first reads all of the one before from the cache; by default
      # the second turn's first reads only the tools, behind a system prompt that changed.
      [_ | later] = stable["calls"]
      assert Enum.all?(later, &(&1["cached_tokens"] > 0))
      {per_turn, _requests} = runs["per_turn"]
      assert stable["cached_tokens"] > per_turn["cached_tokens"]
      assert stable["input_tokens"] < per_turn["input_tokens"]
    end

    test "task_list: by default the turns after the list changed are refused, stable none" do
      runs =
        for system_prompt <- ["per_turn", "stable"], into: %{} do
          fake = start_fake()

          {:ok, plan} =
            Bench.plan(
              config: anthropic(fake, system_prompt: system_prompt),
              only: ["task_list"],
              history: nil
            )

          report = Bench.live(plan)
          assert Bench.passed?(report), Bench.markdown(report)
          [run] = scenario(report, "task_list")["runs"]
          {system_prompt, {run, FakeOpenAI.requests(fake)}}
        end

      # Six answers. By default the second and third turns each begin with a system prompt
      # holding the list the turn before left, so each turn's first call carries blocks made
      # under the old one: refused, and sent again without thinking, once a change; the
      # conversation lets those blocks go, and the turn's second call is not refused.
      {per_turn, requests} = runs["per_turn"]
      assert per_turn["model_calls"] == 6

      assert %{"system_changes" => 2, "thinking_resent" => 2, "turn_contexts" => 0} =
               per_turn["prefix"]

      assert [200, 200, 400, 200, 200, 400, 200, 200] =
               Enum.map(requests, & &1.status)

      # Stable, the list goes with the turn, and nothing in front of what was sent changes.
      {stable, requests} = runs["stable"]

      assert %{"system_changes" => 0, "tools_changes" => 0, "thinking_resent" => 0} =
               stable["prefix"]

      assert stable["prefix"]["turn_contexts"] == 2
      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
      assert [_one] = requests |> Enum.map(& &1.system) |> Enum.uniq()
    end
  end

  # Issue #590 (Decision 867): `long_turn` is thirteen calls of one turn on `build`, with no
  # task list. The list's tools are there from the first call on a model that binds its
  # thinking, so nothing in front of the first call's thinking changes at the eleventh,
  # and an enforced account refuses nothing; where they came at the eleventh, the three
  # calls from there were each refused once.
  describe "issue #590's long turn" do
    test "thirteen calls on build with thinking_binding: error: no tools change, nothing refused" do
      fake = start_fake()

      {:ok, plan} =
        Bench.plan(
          config: anthropic(fake, thinking_binding: "error"),
          only: ["long_turn"],
          history: nil
        )

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)

      [run] = scenario(report, "long_turn")["runs"]
      assert run["model_calls"] == 13

      assert %{"system_changes" => 0, "tools_changes" => 0, "thinking_resent" => 0} =
               run["prefix"]

      requests = FakeOpenAI.requests(fake)
      assert length(requests) == 13
      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
    end
  end

  # Issue #606 (Decision 871): `loop_turn` is a `/loop` turn and then a person's turn. On a
  # model that binds its thinking, `goal_complete` is offered on both, so the person's turn
  # changes nothing in front of the loop's thinking; where it was offered on the loop's turn
  # alone (Decision 679, kept for a model that does not bind), the person's turn changed the
  # tools and its first call was refused once. The stand-in binds every model's thinking,
  # Claude Opus 5's too, which is how that case is shown.
  describe "issue #606's loop turn" do
    test "a loop's turn and a person's with thinking_binding: error: no tools change, nothing refused" do
      fake = start_fake()

      {:ok, plan} =
        Bench.plan(
          config: anthropic(fake, thinking_binding: "error"),
          only: ["loop_turn"],
          history: nil
        )

      report = Bench.live(plan)
      assert Bench.passed?(report), Bench.markdown(report)

      [run] = scenario(report, "loop_turn")["runs"]
      assert run["model_calls"] == 6
      assert Enum.all?(run["checks"], & &1["passed"]), inspect(run["checks"])

      assert %{"system_changes" => 0, "tools_changes" => 0, "thinking_resent" => 0} =
               run["prefix"]

      requests = FakeOpenAI.requests(fake)
      assert length(requests) == 6
      assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))
    end

    test "where goal_complete comes and goes, the person's turn changes the tools and is refused" do
      fake = start_fake()
      config = anthropic(fake, thinking_binding: "error", model: "claude-opus-5")
      {:ok, plan} = Bench.plan(config: config, only: ["loop_turn"], history: nil)

      [run] = plan |> Bench.live() |> scenario("loop_turn") |> Map.fetch!("runs")
      assert run["succeeded"] and run["model_calls"] == 6

      # The person's turn's first call, once: the conversation lets the loop's blocks go
      # then, and the turn's other two calls are not refused.
      assert %{"tools_changes" => 1, "thinking_resent" => 1} = run["prefix"]
      assert length(FakeOpenAI.requests(fake)) == 7
    end
  end

  # Issue #616: a long session that writes and revises a plan and a checklist and compacts
  # on the way, with the scratchpad and without it. Its window is its own, whatever the
  # person's say.
  describe "issue #616's long session" do
    test "runs by name, both under their window, the one without the scratchpad on build as it was" do
      assert {:ok, [pad, plain]} =
               LiveScenarios.select(nil, ~w(scratchpad_session_without scratchpad_session))

      assert {pad.name, plain.name} == {"scratchpad_session", "scratchpad_session_without"}
      assert pad.prompt == plain.prompt and pad.follow_ups == plain.follow_ups
      assert length(pad.follow_ups) == 7
      assert pad.config[:context_window] == plain.config[:context_window]
      assert pad.config[:context_window] == 24_000
      assert plain.files[".troupe/agents/build.md"] == LiveScenarios.build_without_show()
      refute Map.has_key?(pad.files, ".troupe/agents/build.md")
    end

    # With the scratchpad the plan the person last reads is the document, a `show` and the
    # patches after it; a refused patch changed nothing.
    test "reads the plan as its show and its patches left it" do
      {:ok, [pad]} = LiveScenarios.select(nil, ["scratchpad_session"])
      plan = "1. Copy the notes.\n2. Switch the reads.\n3. Roll back: restore the SQLite file.\n"

      counted = %{
        "name" => "plan.md",
        "old_string" => "1. Copy the notes.\n",
        "new_string" => "1. Copy the notes.\n1a. Compare the row counts.\n"
      }

      missed = %{"name" => "plan.md", "old_string" => "not in it", "new_string" => "read-only"}
      kept = %{"name" => "plan.md", "new_string" => "4. Keep the SQLite file read-only."}

      events = [
        typed(1),
        call(2, "c1", "show", %{"name" => "Plan.md", "title" => "Plan", "content" => plan}),
        done(3, "c1", "show", true),
        event(4, "scratch_updated", %{"name" => "plan.md", "version" => 1}),
        reply(5, "The plan is in plan.md."),
        typed(6),
        reply(7, "two"),
        typed(8),
        reply(9, "three"),
        typed(10),
        reply(11, "The copy step takes 400 seconds."),
        event(12, "compacted", %{}),
        typed(13),
        call(14, "c2", "patch", counted),
        done(15, "c2", "patch", true),
        event(16, "scratch_updated", %{"name" => "plan.md", "version" => 2}),
        call(17, "c3", "patch", missed),
        done(18, "c3", "patch", false),
        reply(19, "plan.md is revised."),
        typed(20),
        typed(21),
        typed(22)
      ]

      {[], checks} = pad.measure.(%{events: events})
      assert for({name, _label, false} <- checks, do: name) == ["kept"]

      events = events ++ [call(30, "c4", "patch", kept), done(31, "c4", "patch", true)]
      {[], checks} = pad.measure.(%{events: events})
      assert for({name, _label, false} <- checks, do: name) == []
    end

    test "a run says what it spent from its first compaction on" do
      fake =
        start_fake(
          scripts: [
            {"read the notes",
             Enum.map(1..8, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]}) ++
               [{:text, "Read them all."}]}
          ]
        )

      scenario = %Scenario{
        name: "windowed",
        title: "reads under a window of the scenario's own",
        prompt: "read the notes, one at a time",
        files: Map.new(1..8, &{"notes/#{&1}.txt", "note #{&1}\n"}),
        config: [context_window: 5_000, compact_at: 0.8],
        measure: fn _ctx -> {[], []} end
      }

      {:ok, plan} = Bench.plan(config: person(fake), scenarios: [scenario], history: nil)
      [run] = plan |> Bench.live() |> scenario("windowed") |> Map.fetch!("runs")

      since = run["since_compaction"]
      [first | _] = Enum.drop_while(run["calls"], &(not &1["summariser"]))
      assert first["summariser"]
      assert since["model_calls"] < run["model_calls"]
      assert since["output_tokens"] < run["output_tokens"]
      assert since["cost_micros"] < run["cost_micros"]
    end

    test "a scenario's window is the run's model's, whatever the person's say" do
      fake =
        start_fake(
          scripts: [
            {"read the notes",
             Enum.map(1..8, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]}) ++
               [{:text, "Read them all."}]}
          ]
        )

      scenario = %Scenario{
        name: "windowed",
        title: "reads under a window of the scenario's own",
        prompt: "read the notes, one at a time",
        files: Map.new(1..8, &{"notes/#{&1}.txt", "note #{&1}\n"}),
        config: [context_window: 5_000, compact_at: 0.8],
        measure: fn _ctx -> {[], []} end
      }

      config = person(fake, windows: %{FakeOpenAI.model() => 1_000_000})
      {:ok, plan} = Bench.plan(config: config, scenarios: [scenario], history: nil)

      [run] = plan |> Bench.live() |> scenario("windowed") |> Map.fetch!("runs")
      assert run["compactions"] >= 1, inspect(run["error"])
    end

    test "a scenario's wall clock is its run's, the runner's deadline too" do
      fake = start_fake(done_ms: 2_000)
      [write_file] = only(["write_file"])
      long = %{write_file | config: [wall_clock_ms: 30_000]}

      {:ok, plan} =
        Bench.plan(
          config: person(fake),
          scenarios: [long],
          limits: [wall_clock_ms: 1_000],
          history: nil
        )

      assert [%{"succeeded" => true, "error" => nil}] =
               plan |> Bench.live() |> scenario("write_file") |> Map.fetch!("runs")
    end
  end

  # Issue #554: three tasks on `orchestrate` beside the same tasks on the default agent.
  describe "issue #554's orchestrate pairs" do
    @pairs ~w(fix_test_orchestrate rename_symbol_orchestrate follow_steps_orchestrate)

    test "each is its pair's task on orchestrate, run by name and in no suite" do
      assert {:ok, orchestrated} = LiveScenarios.select(nil, @pairs)
      assert Enum.map(orchestrated, & &1.name) == @pairs

      for scenario <- orchestrated do
        [plain] = only([String.replace_suffix(scenario.name, "_orchestrate", "")])

        assert {scenario.prompt, scenario.files, scenario.outcome, scenario.follow_ups} ==
                 {plain.prompt, plain.files, plain.outcome, plain.follow_ups}

        assert scenario.config[:default_agent] == "orchestrate"
        assert plain.config[:default_agent] == nil
      end

      for suite <- LiveScenarios.suites() do
        {:ok, scenarios} = LiveScenarios.select(suite)
        refute Enum.any?(scenarios, &(&1.name in @pairs)), suite
      end
    end

    test "a run on orchestrate gets the change done through a subagent, every call of its tree in the record" do
      fake =
        start_fake(
          scripts: [
            {"line_total becomes subtotal", renamer()},
            {"Rename the function", briefer()}
          ]
        )

      {:ok, plan} =
        Bench.plan(config: person(fake), only: ["rename_symbol_orchestrate"], history: nil)

      report = Bench.live(plan)
      entry = scenario(report, "rename_symbol_orchestrate")
      assert entry["passed"], Bench.markdown(report)
      assert [%{"succeeded" => true, "error" => nil} = run] = entry["runs"]

      assert Enum.map(run["checks"], &{&1["name"], &1["passed"]}) ==
               [{"old_name_gone", true}, {"test_kept", true}, {"delegated", true}]

      # The root's two calls and the implementer's three, and the cost is all five's.
      assert run["calls"] |> Enum.map(& &1["agent"]) |> Enum.frequencies() ==
               %{"root" => 2, "root/implementer#1" => 3}

      assert run["model_calls"] == 5
      assert run["cost_micros"] == run["calls"] |> Enum.map(& &1["cost_micros"]) |> Enum.sum()
    end

    test "on orchestrate, a root that edits rather than delegates changes nothing and scores nothing" do
      # The default agent's script: orchestrate is refused every edit it makes.
      fake = start_fake()

      {:ok, plan} =
        Bench.plan(config: person(fake), only: ["rename_symbol_orchestrate"], history: nil)

      [run] = plan |> Bench.live() |> scenario("rename_symbol_orchestrate") |> Map.fetch!("runs")
      assert %{"succeeded" => false, "outcome" => false} = run

      assert %{"delegated" => false, "old_name_gone" => false} =
               Map.new(run["checks"], &{&1["name"], &1["passed"]})
    end
  end

  # What the orchestrate root of `rename_symbol_orchestrate` sends, against the stand-in.
  defp briefer do
    [
      {:tools,
       [
         {"delegate",
          %{
            "agent" => "implementer",
            "goal" => "line_total becomes subtotal in lib/, and elixir shop_test.exs passes.",
            "context" => "lib/cart.exs defines it; lib/receipt.exs and lib/discount.exs call it.",
            "constraints" => "Only the three files under lib/.",
            "deliverable" => "The rename, and the test's result.",
            "do_not" => "Do not change shop_test.exs."
          }}
       ]},
      {:text, "The implementer renamed it, and the tests pass."}
    ]
  end

  # And its implementer: the default agent's edits, then a finish in its parts.
  defp renamer do
    [
      {:tools,
       for {path, old} <- [
             {"lib/cart.exs", "def line_total("},
             {"lib/receipt.exs", "Shop.Cart.line_total("},
             {"lib/discount.exs", "Shop.Cart.line_total("}
           ] do
         {"edit_file",
          %{
            "path" => path,
            "old_string" => old,
            "new_string" => String.replace(old, "line_total", "subtotal")
          }}
       end},
      {:tools,
       [
         {"edit_file",
          %{
            "path" => "lib/cart.exs",
            "old_string" => "&line_total/1",
            "new_string" => "&subtotal/1"
          }}
       ]},
      {:tools,
       [
         {"finish",
          %{
            "summary" => "Renamed line_total to subtotal in lib/.",
            "ran" => "nothing",
            "passed" => "nothing",
            "unverified" => "the test",
            "needs" => "nothing"
          }}
       ]}
    ]
  end

  # The stand-in as Anthropic's API, serving Claude Opus 5.5 at its price.
  defp anthropic(fake, extra \\ []) do
    Troupe.Config.load(
      nil,
      [
        provider: "anthropic",
        base_url: fake.url,
        api_key: @key,
        model: "claude-opus-5-5",
        prices: %{
          "claude-opus-5-5" => %{
            "input" => 4,
            "output" => 20,
            "cache_read" => 0.2,
            "cache_write" => 5
          }
        }
      ] ++ extra
    )
  end

  describe "a benchmark (Decision 775)" do
    test "smoke unless told otherwise; standard; scenarios by name; an unknown one refused" do
      fake = start_fake()

      assert {:ok, plan} = Bench.plan(config: person(fake), history: nil)
      assert plan.suite == "smoke"
      assert Enum.map(plan.scenarios, & &1.name) == ~w(write_file fix_test delegate recover)
      assert Bench.describe_plan(plan) =~ "The smoke suite: write_file, fix_test, delegate, recover."

      assert {:ok, plan} = Bench.plan(config: person(fake), suite: "standard", history: nil)

      assert Enum.map(plan.scenarios, & &1.name) ==
               ~w(write_file fix_test delegate recover rename_symbol implement_spec large_log precise_edit follow_steps answer_only)

      assert plan.cap_micros == 960_000 * 10

      assert {:ok, plan} =
               Bench.plan(config: person(fake), only: ["large_log", "write_file"], history: nil)

      assert Enum.map(plan.scenarios, & &1.name) == ~w(write_file large_log)
      assert Bench.describe_plan(plan) =~ "The scenarios asked for: write_file, large_log."

      assert {:error, "no live suite is called huge; there are smoke and standard"} =
               Bench.plan(config: person(fake), suite: "huge", history: nil)

      assert {:error, why} = Bench.plan(config: person(fake), only: ["nope"], history: nil)
      assert why =~ "no live scenario is called nope; there are write_file, fix_test"
      assert FakeOpenAI.requests(fake) == []
    end

    test "the standard suite against the stand-in: every task's outcome and checks hold, and a summary" do
      fake = start_fake()
      {:ok, plan} = Bench.plan(config: person(fake), suite: "standard", history: nil)

      report = Bench.live(plan)

      assert Bench.passed?(report), Bench.markdown(report)
      assert %{"suite" => "troupe bench", "live_suite" => "standard"} = report
      assert length(report["scenarios"]) == 10

      for entry <- report["scenarios"] do
        assert %{"passed" => true, "error" => nil} = entry
        assert Enum.all?(entry["checks"], & &1["passed"]), inspect(entry["checks"])
      end

      # The log was searched, not read whole: the largest result is the grep's.
      [log_run] = scenario(report, "large_log")["runs"]
      assert log_run["largest_tool_result_bytes"] < 16_384
      assert [%{"name" => "grep", "cut" => false}, %{"name" => "write_file"}] = log_run["tool_calls"]

      [answer_run] = scenario(report, "answer_only")["runs"]
      assert %{"model_calls" => 1, "tool_calls" => [], "largest_tool_result_bytes" => 0} = answer_run

      assert %{
               "scenarios" => 10,
               "runs" => 10,
               "succeeded" => 10,
               "success_rate" => 1.0,
               "success_low" => 0.722,
               "success_high" => 1.0,
               "cost_micros" => cost,
               "cost_per_success_micros" => per_success
             } = report["summary"]

      assert per_success == round(cost / 10)
      assert cost == report["scenarios"] |> Enum.flat_map(& &1["runs"]) |> Enum.map(& &1["cost_micros"]) |> Enum.sum()

      md = Bench.markdown(report)
      assert md =~ "| 10 scenarios together | |"
      assert md =~ "| runs that succeeded | 10 of 10, 1.0 (95% interval 0.722 to 1.0) |"
      assert md =~ "| precise_edit | settings.conf was edited in place, not written whole (1 of 1) | yes | ok |"
      assert md =~ "| rename_symbol | outcome: `elixir shop_test.exs` exits 0 | 1 of 1 | ok |"
      assert md =~ "live against openai/standin-1: 10 scenarios, 1 run each, every run succeeded."
    end

    test "nothing done is nothing scored: each new task fails untouched" do
      fake = start_fake(scripts: [])

      {:ok, plan} =
        Bench.plan(
          config: person(fake),
          only: ~w(rename_symbol implement_spec large_log precise_edit follow_steps answer_only),
          history: nil
        )

      report = Bench.live(plan)

      # The stand-in says "done" to everything and touches nothing: no outcome holds, and
      # answer_only's reply is not the number.
      for entry <- report["scenarios"] do
        assert [%{"succeeded" => false}] = entry["runs"], entry["name"]
      end

      assert report["summary"]["succeeded"] == 0
      assert report["summary"]["cost_per_success_micros"] == nil
    end

    test "a run whose last allowed call ends the turn ended by itself (#405); one cut off did not" do
      fake = start_fake()

      # write_file takes two calls: the write, then the answer.
      {:ok, plan} =
        Bench.plan(
          config: person(fake),
          scenarios: only(["write_file"]),
          limits: [max_turns: 2],
          history: nil
        )

      assert [%{"succeeded" => true, "error" => nil, "model_calls" => 2, "stop_reason" => "end_turn"}] =
               scenario(Bench.live(plan), "write_file")["runs"]

      {:ok, plan} =
        Bench.plan(
          config: person(fake),
          scenarios: only(["write_file"]),
          limits: [max_turns: 1],
          history: nil
        )

      assert [%{"succeeded" => false, "error" => error, "stop_reason" => "tool_use"}] =
               scenario(Bench.live(plan), "write_file")["runs"]

      assert error == "the run's budget stopped it (max_turns)"
    end

    test "each tool call is in the run's record, a cut one says so (#406), and --keep keeps the run",
         %{tmp_dir: dir} do
      # 3,000 lines of 40 bytes: a read returns 2,000 of them, cut at the 32 KiB default.
      big = Enum.map_join(1..3_000, fn i -> String.pad_trailing("line #{i}", 39, ".") <> "\n" end)

      scenario = %Scenario{
        name: "big_read",
        title: "a read too large to send whole",
        prompt: "Read big.txt and say what it holds.",
        files: %{"big.txt" => big},
        measure: fn _ctx -> {[], []} end
      }

      fake =
        start_fake(
          scripts: [
            {"Read big.txt",
             [{:tools, [{"read_file", %{"path" => "big.txt"}}]}, {:text, "Numbered lines."}]}
          ]
        )

      keep = Path.join(dir, "kept")

      {:ok, plan} =
        Bench.plan(config: person(fake), scenarios: [scenario], keep: keep, history: nil)

      assert Bench.describe_plan(plan) =~ "Each run's workspace and session log are kept under #{keep}."

      report = Bench.live(plan)
      [run] = scenario(report, "big_read")["runs"]

      assert [
               %{
                 "agent" => "root",
                 "name" => "read_file",
                 "ok" => true,
                 "ms" => ms,
                 "result_bytes" => bytes,
                 "cut" => true
               }
             ] = run["tool_calls"]

      assert is_integer(ms)
      # Kept as a blob in the log, measured as the text the model was given.
      assert bytes > 32_000 and bytes < 33_000
      assert run["largest_tool_result_bytes"] == bytes
      assert metric(scenario(report, "big_read"), "median_largest_tool_result") == bytes

      # The run's directories, under one of the bench's own.
      assert String.starts_with?(report["kept_in"], keep)
      assert File.read!(Path.join([report["kept_in"], "big_read-1", "work", "big.txt"])) == big

      assert [_log] =
               Path.wildcard(Path.join([report["kept_in"], "big_read-1", "state", "**", "events.jsonl"]))
    end

    test "the interval a success rate has, from its runs" do
      assert Live.wilson(3, 3) == {0.438, 1.0}
      assert Live.wilson(2, 3) == {0.208, 0.939}
      assert Live.wilson(0, 3) == {0.0, 0.562}
      assert Live.wilson(30, 30) == {0.886, 1.0}
      assert Live.wilson(0, 0) == {0.0, 1.0}
    end

    test "--compare sets every scenario both benches ran beside each other, per run and per success",
         %{tmp_dir: dir} do
      path = Path.join(dir, "results.jsonl")

      # Then: two scenarios, one run each, one failed. Now: three runs each, all succeeded.
      for {scenario, cost, ok} <- [{"write_file", 4_000, true}, {"recover", 6_000, false}] do
        History.append(path, %{line("2026-10-01T10:00:00Z", "0.8.1-beta", "openai/a", cost, ok, 1) | "scenario" => scenario})
      end

      for scenario <- ["write_file", "recover"], n <- 1..3 do
        History.append(path, %{line("2026-10-02T10:00:00Z", "0.8.2-beta", "openai/a", 3_000, true, n) | "scenario" => scenario})
      end

      assert {:ok, table} = Bench.compare(history: path)
      assert table =~ "| all | scenarios in both | 2 scenarios | 2 scenarios |  |"
      assert table =~ "| all | runs that succeeded | 0.5 | 1.0 | +0.5 |"
      # $0.010 in all for one success, then $0.018 for six.
      assert table =~ "| all | cost per success | $0.0100 | $0.0030 | -70% |"
      assert table =~ "| all | cost per run | $0.0050 | $0.0030 | -40% |"
    end
  end

  test "a file's outcome is its text, whatever line endings and trailing newline it has", %{
    tmp_dir: dir
  } do
    scenario = %Scenario{
      name: "s",
      title: "s",
      prompt: "p",
      outcome: {:file, "a.txt", "Pemberton\n"},
      measure: fn _ctx -> {[], []} end
    }

    for written <- ["Pemberton\n", "Pemberton", "Pemberton\r\n", "Pemberton\n\n"] do
      File.write!(Path.join(dir, "a.txt"), written)
      assert Scenario.outcome(scenario, dir), inspect(written)
    end

    File.write!(Path.join(dir, "a.txt"), "Pemberton the cat\n")
    refute Scenario.outcome(scenario, dir)
  end

  # The call that writes a compaction's summary has no llm_request or llm_response: the
  # `compacted` that takes its answer carries it (Decision 769), and it is a call like any
  # other, with no times since nothing announced it.
  test "a compaction's summary is a model call, with what its prompt was made of and cost" do
    bytes = %{
      "system" => 10,
      "tools" => 20,
      "conversation" => 30,
      "tool_results" => 5,
      "total" => 60
    }

    usage = %{"input_tokens" => 40, "output_tokens" => 7, "cache_read" => 3, "cache_write" => 2}

    events = [
      %Event{seq: 1, type: "llm_request", agent: ["root"], data: %{"prompt_bytes" => bytes}},
      %Event{
        seq: 2,
        type: "llm_response",
        agent: ["root"],
        data: %{"usage" => usage, "gateway" => %{"cost_micros" => 90}}
      },
      %Event{seq: 3, type: "compacted", agent: ["root"], data: %{"summary" => "old, no call"}},
      %Event{
        seq: 4,
        type: "compacted",
        agent: ["root"],
        data: %{
          "prompt_bytes" => %{bytes | "total" => 61},
          "usage" => usage,
          "gateway" => %{"cost_micros" => 12}
        }
      }
    ]

    timings = %{2 => %{latency: 400, first: 120, bytes: bytes}}

    assert [reply, summary] = Live.calls(events, timings)

    assert %{
             "summariser" => false,
             "prompt_bytes" => 60,
             "system_bytes" => 10,
             "tool_definition_bytes" => 20,
             "conversation_bytes" => 30,
             "tool_result_bytes" => 5,
             "input_tokens" => 42,
             "cached_tokens" => 3,
             "output_tokens" => 7,
             "cost_micros" => 90,
             "latency_ms" => 400,
             "first_token_ms" => 120
           } = reply

    assert %{
             "summariser" => true,
             "prompt_bytes" => 61,
             "cost_micros" => 12,
             "latency_ms" => nil,
             "first_token_ms" => nil
           } = summary
  end

  # In a release the VM's own runtime comes first on the PATH, and an `elixir` started on
  # it has no boot file: a command outcome runs without it.
  test "a command outcome runs with the PATH less the release's own runtime" do
    bin = "/opt/troupe/erts-16.4/bin"
    path = Enum.join([bin, "/usr/local/bin", "/opt/troupe/erts-16.4/bin/", "/usr/bin"], ":")

    assert Scenario.command_path(path, bin) == "/usr/local/bin:/usr/bin"
    assert Scenario.command_path(path, nil) == path
  end

  defp line(bench, version, model, cost, ok, n) do
    %{
      "schema" => 1,
      "bench" => bench,
      "version" => version,
      "scenario" => "write_file",
      "run" => n,
      "model" => model,
      "succeeded" => ok,
      "cost_micros" => cost,
      "wall_ms" => 1_000,
      "model_calls" => 2,
      "input_tokens" => 8_000,
      "cached_tokens" => 0,
      "output_tokens" => 100,
      "calls" => [%{"latency_ms" => 400, "first_token_ms" => 100}]
    }
  end

  defp scenario(report, name), do: Enum.find(report["scenarios"], &(&1["name"] == name))

  # A run's events as a measure reads them: the root's, in the order they were logged.
  defp event(seq, type, data), do: %Event{seq: seq, type: type, agent: ["root"], data: data}
  defp typed(seq), do: event(seq, "user_input", %{"source" => "user", "text" => "next"})

  defp call(seq, id, name, args),
    do: event(seq, "tool_call_started", %{"call_id" => id, "name" => name, "args" => args})

  defp done(seq, id, name, ok),
    do: event(seq, "tool_call_completed", %{"call_id" => id, "name" => name, "ok" => ok})

  defp reply(seq, text),
    do:
      event(seq, "llm_response", %{
        "message" => %{"content" => [%{"type" => "text", "text" => text}]}
      })

  defp tool(run, name), do: Enum.find(run["tools"], &(&1["name"] == name))

  defp metric(entry, name),
    do: entry["metrics"] |> Enum.find(&(&1["name"] == name)) |> Map.fetch!("value")
end
