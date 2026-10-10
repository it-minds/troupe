defmodule Troupe.BenchOnboardingTest do
  @moduledoc """
  The offline bench's onboarding scenarios (issue #516's slice 8, Decision 834): for each
  other tool, a repository with that tool's files only, `troupe onboard`'s plan accepted
  whole, then a session whose note holds only when the tool's rule reached its prompt.

  `async: false`: while a scenario runs the bench points `TROUPE_CONFIG_HOME` and
  `TROUPE_STATE_HOME` at its own directories, and two tests here set `:onboard_sources`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Agent.Definitions
  alias Troupe.Bench
  alias Troupe.Bench.{Onboarding, Runner, Scenario}
  alias Troupe.Instructions

  @names ~w(onboard_claude_code onboard_opencode onboard_cursor onboard_copilot)

  # A source that brings `CLAUDE.md` into `AGENTS.md` and loses its rule on the way.
  defmodule Lossy do
    @moduledoc false
    @behaviour Troupe.Onboard.Source

    @impl true
    def proposals(workspace, _opts) do
      bytes = File.read!(Path.join(workspace, "CLAUDE.md"))

      [
        %{
          target: :workspace,
          path: "AGENTS.md",
          content: "# Harbour notes\n",
          source: "CLAUDE.md",
          source_hash: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
          notes: []
        }
      ]
    end
  end

  setup_all do
    %{report: Bench.run(only: @names)}
  end

  test "each tool's files are onboarded, its rule reaches the prompt and the note holds it",
       %{report: report} do
    assert Bench.passed?(report), Bench.markdown(report)
    assert Enum.map(report["scenarios"], & &1["name"]) == @names

    for entry <- report["scenarios"] do
      assert %{"what" => "note.txt holds what was asked for", "passed" => true} = entry["outcome"]
      assert %{"passed" => true} = check(entry, "onboarded")
      assert value(entry, "instruction_bytes") > 0
    end

    # AGENTS.md, an agent and a command; the person's CLAUDE.local.md left out.
    assert {3, 1} = files(report, "onboard_claude_code")
    # Two agents and a command; the disabled agent left out.
    assert {3, 1} = files(report, "onboard_opencode")
    # Two rules; the one in a folder under .cursor/rules left out.
    assert {2, 1} = files(report, "onboard_cursor")
    # AGENTS.md and a rule.
    assert {2, 0} = files(report, "onboard_copilot")

    assert Bench.markdown(report) =~
             "| onboard_claude_code | outcome: note.txt holds what was asked for | yes |  | ok |"
  end

  # The measure reads the first request's system prompt; what it counts is what the
  # loader makes of the files onboarding wrote, and for opencode the agent's prompt.
  test "the instructions' bytes are what the onboarded files put in the prompt",
       %{report: report} do
    dir = scratch()

    for %Scenario{} = scenario <- Onboarding.all() do
      root = onboarded(scenario, Path.join(dir, scenario.name))

      text =
        Runner.with_env(Runner.isolation(Path.join(dir, scenario.name)), fn ->
          instructions = root |> Instructions.load(nil, []) |> Instructions.to_prompt()

          case scenario.agent do
            nil -> instructions
            agent -> Definitions.load(root) |> Definitions.fetch!(agent) |> Map.fetch!(:prompt)
          end
        end)

      expected = text |> String.replace(root, "<workspace>") |> byte_size()

      assert {scenario.name, value(entry(report, scenario.name), "instruction_bytes")} ==
               {scenario.name, expected}
    end
  end

  # The reproduction on the chunk's tip: no session reads CLAUDE.md (Decision 828).
  test "without onboarding, the Claude Code fixture's rule does not reach the prompt" do
    scenario = %{claude_code() | prepare: nil}
    run = Runner.run(scenario, scratch())

    assert run.error == nil
    assert run.record["outcome"] == false
    assert {"files_written", _label, _unit, 0} = List.keyfind(run.metrics, "files_written", 0)
    assert {"onboarded", _label, false} = List.keyfind(run.checks, "onboarded", 0)
  end

  describe "a fixture whose onboarding" do
    setup do
      on_exit(fn -> Application.delete_env(:troupe_core, :onboard_sources) end)
    end

    test "writes nothing fails its scenario" do
      Application.put_env(:troupe_core, :onboard_sources, [])
      report = Bench.run(only: ["onboard_claude_code"])

      refute Bench.passed?(report)
      assert files(report, "onboard_claude_code") == {0, 0}

      assert Bench.markdown(report) =~
               "FAILED onboard_claude_code/onboarded, onboard_claude_code/outcome."
    end

    test "loses the rule fails its scenario" do
      Application.put_env(:troupe_core, :onboard_sources, [Lossy])
      report = Bench.run(only: ["onboard_claude_code"])

      refute Bench.passed?(report)
      assert files(report, "onboard_claude_code") == {1, 0}
      assert Bench.markdown(report) =~ "FAILED onboard_claude_code/outcome."
    end
  end

  # A directory outside any repository, as the bench's own are: under the checkout, the
  # loader would read the checkout's AGENTS.md too.
  defp scratch do
    dir = Path.join(System.tmp_dir!(), "troupe-bench-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # The fixture's files in `dir/work`, onboarded as the scenario does it, and the
  # workspace's real path.
  defp onboarded(scenario, dir) do
    Enum.each(~w(work home config state), &File.mkdir_p!(Path.join(dir, &1)))
    Scenario.seed(scenario, Path.join(dir, "work"))
    {:ok, workspace} = Troupe.Workspace.new(Path.join(dir, "work"))

    Onboarding.onboard(%{
      workspace: workspace.root_real,
      home: Path.join(dir, "home"),
      config_dir: Path.join(dir, "config"),
      state_dir: Path.join(dir, "state")
    })

    workspace.root_real
  end

  defp claude_code, do: Enum.find(Onboarding.all(), &(&1.name == "onboard_claude_code"))

  defp files(report, name) do
    entry = entry(report, name)
    {value(entry, "files_written"), value(entry, "files_left_out")}
  end

  defp entry(report, name), do: Enum.find(report["scenarios"], &(&1["name"] == name))
  defp value(entry, name), do: Enum.find(entry["metrics"], &(&1["name"] == name))["value"]
  defp check(entry, name), do: Enum.find(entry["checks"], &(&1["name"] == name))
end
