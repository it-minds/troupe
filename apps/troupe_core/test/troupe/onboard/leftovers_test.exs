defmodule Troupe.Onboard.LeftoversTest do
  @moduledoc """
  Onboarding's leftovers after #516's second half (D102, Decision 854): a file onboarding
  brought in says where it went in `context.get`'s listing rather than asking for `troupe
  onboard`; the first notice finds other tools' files below the root too, within the walk's
  bounds; a second `troupe onboard` counts what it brought in as unchanged instead of
  listing each file; and a glob in opencode's `instructions` is held to `.gitignore` and
  leaves `node_modules` alone. Every workspace is a git repository made with `git`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Onboard
  alias Troupe.Onboard.{Instructions, Notice}

  @now "2026-10-10T09:00:00Z"
  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"
  @gemini "- Never edit the files under `priv/static` by hand: they are built.\n"
  @style "---\nalwaysApply: true\n---\nBe brief.\n"

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-onboard-left-#{System.unique_integer([:positive])}")

    dirs = Map.new(~w(workspace config home state), &{String.to_atom(&1), Path.join(base, &1)})
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(base) end)
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: dirs.workspace)

    opts = [
      sources: [Instructions],
      config_dir: dirs.config,
      home: dirs.home,
      state_dir: dirs.state,
      now: @now
    ]

    Map.merge(dirs, %{base: base, opts: opts})
  end

  defp write_all!(dir, files) do
    for {rel, body} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end
  end

  # Every proposal the plan holds, written as `troupe onboard --yes` and a person's yes to
  # a new `AGENTS.md` would write it.
  defp onboard_all!(ctx) do
    %{proposals: items} = Onboard.plan(ctx.workspace, ctx.opts)
    for item <- items, do: {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)
    items
  end

  defp reasons(ws) do
    for %{"path" => path, "reason" => reason} <- Troupe.Instructions.provenance(ws, nil)["files"],
        into: %{},
        do: {Path.relative_to(path, ws), reason}
  end

  # On the chunk's tip every one of them still said "not read: run troupe onboard".
  test "a file onboarding brought in says where it went; one it did not, to run troupe onboard",
       ctx do
    write_all!(ctx.workspace, %{
      "CLAUDE.md" => @claude,
      ".cursor/rules/style.mdc" => @style
    })

    before = reasons(ctx.workspace)
    assert before["CLAUDE.md"] == "not read: run troupe onboard"
    assert before[".cursor/rules/style.mdc"] == "not read: run troupe onboard"

    onboard_all!(ctx)
    write_all!(ctx.workspace, %{"GEMINI.md" => @gemini})

    after_onboarding = reasons(ctx.workspace)
    assert after_onboarding["CLAUDE.md"] == "not read: onboarded into AGENTS.md"

    assert after_onboarding[".cursor/rules/style.mdc"] ==
             "not read: onboarded into .troupe/rules/style.md"

    assert after_onboarding["GEMINI.md"] == "not read: run troupe onboard"

    # Still not read: the prompt has none of them, and the onboarded files are read instead.
    loaded = Troupe.Instructions.load(ctx.workspace, nil)
    skipped = for %{status: :skipped} = f <- loaded.files, do: Path.basename(f.path)
    assert Enum.sort(skipped) == ["CLAUDE.md", "GEMINI.md", "style.mdc"]
    assert Troupe.Instructions.to_prompt(loaded) =~ "Run the tests with `mix test`"
  end

  # On the chunk's tip the notice looked at the root alone: a repository whose only such
  # file was nested was told nothing, though `troupe onboard` found it.
  test "the first notice finds a nested CLAUDE.md or Cursor rule, within the walk's bounds",
       ctx do
    ws = ctx.workspace
    opts = Keyword.take(ctx.opts, [:state_dir, :config_dir, :home])

    # Where the walk does not go, nothing is found: node_modules, an ignored directory, a
    # hidden one.
    write_all!(ws, %{
      ".gitignore" => "build/\n",
      "node_modules/pkg/CLAUDE.md" => @claude,
      "build/CLAUDE.md" => @claude,
      ".vendor/CLAUDE.md" => @claude,
      "README.md" => "# r\n"
    })

    refute Instructions.found?(ws)
    assert %{due: "none"} = Notice.onboarding(ws, opts)

    # Untracked, below the root: found, and the notice is due.
    write_all!(ws, %{"services/api/CLAUDE.md" => @claude})
    assert Instructions.found?(ws)
    assert %{due: "first", plan: %{proposals: [item]}} = Notice.onboarding(ws, opts)
    assert item.shown == "services/api/AGENTS.md"

    # A directory's Cursor rule, tracked.
    File.rm!(Path.join(ws, "services/api/CLAUDE.md"))
    refute Instructions.found?(ws)
    write_all!(ws, %{"web/.cursor/rules/style.mdc" => @style})
    {_, 0} = System.cmd("git", ["add", "web"], cd: ws)
    assert Instructions.found?(ws)
    assert %{due: "first"} = Notice.onboarding(ws, opts)
  end

  # On the chunk's tip a second run listed "everything it says is in AGENTS.md already" for
  # each file it had brought in, every run.
  test "a second troupe onboard counts the files it brought in as unchanged", ctx do
    write_all!(ctx.workspace, %{
      "CLAUDE.md" => @claude,
      "GEMINI.md" => @gemini,
      "pkg/CLAUDE.md" => "Run this package's tests from `pkg/`.\n",
      ".cursor/rules/style.mdc" => @style
    })

    assert length(onboard_all!(ctx)) == 3

    assert %{proposals: [], skipped: [], unchanged: 4} = Onboard.plan(ctx.workspace, ctx.opts)

    # A file whose every word an AGENTS.md says, though nothing onboarded it there, is still
    # named, as on a first run.
    write_all!(ctx.workspace, %{
      "lib/AGENTS.md" => "Keep modules small.\n",
      "lib/CLAUDE.md" => "Keep modules small.\n"
    })

    assert %{proposals: [], skipped: [said], unchanged: 4} = Onboard.plan(ctx.workspace, ctx.opts)

    assert said == %{
             source: "lib/CLAUDE.md",
             reason: "everything it says is in lib/AGENTS.md already"
           }
  end

  # On the chunk's tip `**/*.md` proposed every Markdown file `Path.wildcard/1` found,
  # `node_modules` and what `.gitignore` hides among them.
  test "a glob in opencode's instructions honours .gitignore and leaves node_modules alone",
       ctx do
    write_all!(ctx.workspace, %{
      ".gitignore" => "build/\n*.secret.md\n",
      "opencode.json" => ~s({"instructions": ["**/*.md", "build/kept.md"]}),
      "docs/guide.md" => "Write the guide in plain words.\n",
      "notes.secret.md" => "Not for the repository.\n",
      "build/out.md" => "Generated.\n",
      "build/kept.md" => "Named outright.\n",
      "node_modules/pkg/README.md" => "A dependency's readme.\n",
      "web/node_modules/other/README.md" => "Another.\n"
    })

    assert %{proposals: [proposal]} = Instructions.survey(ctx.workspace, ctx.opts)
    sources = [proposal.source | Enum.map(proposal.also_from, & &1.source)]
    assert Enum.sort(sources) == ["build/kept.md", "docs/guide.md"]

    write_all!(ctx.workspace, %{"opencode.json" => ~s({"instructions": ["node_modules/**/*.md"]})})

    assert %{proposals: [], skipped: [skipped]} = Instructions.survey(ctx.workspace, ctx.opts)
    assert skipped.source == "opencode.json"
    assert skipped.reason =~ "matches only files .gitignore hides or under node_modules"
  end
end
