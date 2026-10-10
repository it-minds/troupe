defmodule Troupe.Onboard.LibrarianTest do
  @moduledoc """
  The librarian's prompt after #516's slice 2 (Decision 827): other tools' instruction files
  are not in any prompt, its onboarding pass reads them and proposes through
  `onboard_write`, a new `AGENTS.md` is the person's own question, and the brief still does
  not copy what `AGENTS.md` says (Decision 649). On the chunk's tip the prompt said
  `CLAUDE.md`, `GEMINI.md` and Copilot's file were already in every agent's prompt.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definitions

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "troupe-librarian-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    librarian = workspace |> Definitions.load() |> Definitions.fetch!("librarian")
    %{prompt: librarian.prompt, tools: librarian.tools}
  end

  test "other tools' files are onboarded through onboard_write, not taken for read", ctx do
    assert "onboard_write" in ctx.tools

    refute ctx.prompt =~
             "`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md` — are already"

    assert ctx.prompt =~ "Other coding tools' instruction files are not in any prompt"

    for file <-
          ~w(CLAUDE.md GEMINI.md .github/copilot-instructions.md .cursor/rules/*.mdc .cursorrules),
        do: assert(ctx.prompt =~ "`#{file}`")

    assert ctx.prompt =~ ~s(`target: "workspace"`)
    assert ctx.prompt =~ ~s(`.troupe/rules/<name>.md`: `target: "repo"`)
  end

  test "a new AGENTS.md is the person's own question, and the brief still copies none of it",
       ctx do
    assert ctx.prompt =~ "creating one is the person's own question"
    assert ctx.prompt =~ "never in the same turn as another write"
    assert ctx.prompt =~ "So the brief never copies it"
    assert ctx.prompt =~ "the brief is not a way round their answer"
  end
end
