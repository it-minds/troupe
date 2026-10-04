defmodule Troupe.CLIReferenceTest do
  @moduledoc """
  `troupe --help` and `docs/user/cli-reference.md` are written from two tables (issue
  #124, root Decision 767): the command lines beside the parser, and the harness's
  slash commands. Both used to be written by hand, and the help listed no slash command
  at all. These fail the moment either drifts from the tables, or the command-line
  table from the parser.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Troupe.Cli.Reference, as: Generate
  alias Troupe.CLI

  @page "../../docs/user/cli-reference.md"

  test "troupe --help lists every built-in slash command the harness's table has, by section" do
    help = CLI.help()

    for entry <- Troupe.Commands.builtins() do
      assert help =~ entry["usage"], "troupe --help does not list #{entry["usage"]}"
      assert help =~ entry["summary"], "troupe --help does not say what /#{entry["name"]} does"
    end

    for section <- ~w(session navigate workspace setup agents quit) do
      assert help =~ ~r/^#{String.capitalize(section)}$/m
    end

    assert help =~ CLI.usage()
  end

  test "the command reference is what the two tables say (mix troupe.cli.reference)" do
    page = File.read!(@page)
    assert page == Generate.render(page), "run `mix troupe.cli.reference` in clients/tui"

    for entry <- Troupe.Commands.builtins() do
      assert page =~ entry["summary"], "the reference does not list /#{entry["name"]}"
    end

    for {usage, _what, _argv} <- CLI.commands() do
      assert page =~ "`#{String.replace(usage, "|", "\\|")}`"
    end
  end

  test "every command line the table lists parses, and together they reach every mode" do
    reached =
      for {usage, _what, examples} <- CLI.commands(), argv <- examples do
        assert {:ok, %{mode: mode}} = CLI.parse(argv), "#{usage}: #{inspect(argv)} does not parse"
        mode
      end

    assert Enum.sort(Enum.uniq(reached)) == Enum.sort(modes())
  end

  test "every switch the parser takes is one the help names" do
    help = CLI.usage()

    for {switch, _type} <- CLI.switches() do
      name = switch |> Atom.to_string() |> String.replace("_", "-")
      assert help =~ "--#{name}" or help =~ "--no-#{name}", "troupe --help never names --#{name}"
    end
  end

  # The modes `Troupe.CLI.mode()` says `parse/1` can answer with.
  defp modes do
    {:ok, types} = Code.Typespec.fetch_types(CLI)
    [members] = for {:type, {:mode, {:type, _, :union, members}, []}} <- types, do: members
    for {:atom, _, mode} <- members, do: mode
  end
end
