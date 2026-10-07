defmodule Troupe.InstructionsCheckCLITest do
  @moduledoc """
  `troupe instructions check [--workspace DIR] [--json]` (issue #123, item 10; root
  Decision 810): the instruction files a session in the workspace would read, checked,
  one line per finding with its file and line; 0 for none, 1 for a finding, 2 when the
  workspace cannot be read. The detectors are the harness's
  (`Troupe.Instructions.Check`, whose own suite has a fixture for each); this is the
  command line around them.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Troupe.TestHelpers, only: [tmp_workspace: 1]

  alias Troupe.CLI
  alias Troupe.CLI.Runner

  test "the command line parses, with the workspace and --json" do
    assert {:ok, %{mode: :instructions_check, json: false}} =
             CLI.parse(["instructions", "check"])

    ws = Path.expand(".")

    assert {:ok, %{mode: :instructions_check, json: true, workspace: ^ws}} =
             CLI.parse(["instructions", "check", "--workspace", ".", "--json"])

    assert CLI.usage() =~ "troupe instructions check [--workspace DIR] [--json]"
  end

  test "a planted contradiction between the root and frontend/AGENTS.md is a finding, and exits 1" do
    ws = planted()

    out =
      capture_io(fn ->
        assert Runner.main(["instructions", "check", "--workspace", ws]) == 1
      end)

    assert out =~
             "frontend/AGENTS.md:3: contradiction: how to run the tests: `pnpm test` here, " <>
               "`npm test` in AGENTS.md:3\n"

    # `npm` and `pnpm` may be missing from this machine's PATH too, which is a finding of
    # its own: the count is not this test's to pin.
    assert out =~ ~r/^\d+ findings? in 2 instruction files\.$/m
  end

  test "--json prints the same as one object" do
    ws = planted()

    out =
      capture_io(fn ->
        assert Runner.main(["instructions", "check", "--workspace", ws, "--json"]) == 1
      end)

    assert %{"findings" => findings, "files" => files} = Jason.decode!(out)

    assert %{"file" => "frontend/AGENTS.md", "line" => 3, "message" => message} =
             Enum.find(findings, &(&1["kind"] == "contradiction"))

    assert message =~ "`npm test` in AGENTS.md:3"
    assert Enum.map(files, & &1["file"]) == ["AGENTS.md", "frontend/AGENTS.md"]
  end

  test "instruction files with nothing to say about each other exit 0" do
    ws =
      tmp_workspace(%{
        ".git/HEAD" => "ref: refs/heads/main\n",
        "AGENTS.md" => "# Rules\n\nKeep every change small.\n"
      })

    out =
      capture_io(fn -> assert Runner.main(["instructions", "check", "--workspace", ws]) == 0 end)

    assert out =~ "no findings in 1 instruction file: AGENTS.md"
  end

  test "a workspace that cannot be read exits 2" do
    gone = Path.join(System.tmp_dir!(), "troupe-no-ws-#{System.unique_integer([:positive])}")

    out =
      capture_io(fn ->
        assert Runner.main(["instructions", "check", "--workspace", gone]) == 2
      end)

    assert out =~ "cannot read"
  end

  defp planted do
    tmp_workspace(%{
      ".git/HEAD" => "ref: refs/heads/main\n",
      "AGENTS.md" => "# Tests\n\nRun `npm test` before you push.\n",
      "frontend/AGENTS.md" => "# Frontend\n\nRun `pnpm test` here.\n"
    })
  end
end
