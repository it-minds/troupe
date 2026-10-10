defmodule Troupe.Onboard.LibrarianTest do
  @moduledoc """
  The librarian's prompt (Decisions 827 and 835): other tools' instruction files are not
  in any prompt, and bringing them in is onboarding's, which a session's start asks before
  the librarian starts; the librarian writes the brief only, reading what onboarding wrote
  into `AGENTS.md` and `.troupe/rules/`, and copies none of it (Decision 649). Before
  Decision 835 its first step was an onboarding pass through `onboard_write`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definitions

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "troupe-librarian-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    librarian = workspace |> Definitions.load() |> Definitions.fetch!("librarian")
    %{prompt: librarian.prompt, tools: librarian.tools, description: librarian.description}
  end

  test "it writes the brief only: no onboarding pass, and no onboard_write", ctx do
    refute "onboard_write" in ctx.tools
    assert ctx.tools == ~w(read_file list_files grep remember finish)
    refute ctx.prompt =~ "onboard_write"
    refute ctx.prompt =~ "Offer to onboard"
    refute ctx.description =~ "onboard"

    # It starts from what the repository says about itself, not from a search for other
    # tools' files.
    assert ctx.prompt =~ "1. Read `README.md`"
  end

  test "other tools' files are not its to bring in, and what was left out stays out of the brief",
       ctx do
    for file <-
          ~w(CLAUDE.md GEMINI.md .github/copilot-instructions.md .cursor/rules/*.mdc .cursorrules),
        do: assert(ctx.prompt =~ "`#{file}`")

    assert ctx.prompt =~ "are not in any prompt, and are not yours to bring in"
    assert ctx.prompt =~ "the person answers it before you start"
    assert ctx.prompt =~ "the brief is not a way round their answer"
    assert ctx.prompt =~ "So the brief never copies it"
  end
end
