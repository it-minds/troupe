defmodule Troupe.Onboard.InstructionsTest do
  @moduledoc """
  The instruction files other tools keep, as onboarding proposals (#516, slice 2;
  Decision 827): `CLAUDE.md`, `GEMINI.md` and Copilot's file as additions to the
  `AGENTS.md` in the same directory, merged without saying anything twice; Cursor's and
  Copilot's rules as `.troupe/rules/<name>.md`; the writer's `AGENTS.md` target; and the
  version every write records. On the chunk's tip a `CLAUDE.md` gave no proposal at all.
  """

  use ExUnit.Case, async: true

  alias Troupe.Instructions.Check
  alias Troupe.Onboard
  alias Troupe.Onboard.Instructions

  @now "2026-10-10T09:00:00Z"

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-onboard-instr-#{System.unique_integer([:positive])}")

    dirs = Map.new(~w(workspace config home state), &{String.to_atom(&1), Path.join(base, &1)})
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(base) end)

    opts = [
      sources: [Instructions],
      config_dir: dirs.config,
      home: dirs.home,
      state_dir: dirs.state,
      now: @now
    ]

    Map.merge(dirs, %{base: base, opts: opts})
  end

  @claude """
  # CLAUDE.md

  This repository is a small Elixir service that answers questions about invoices.

  @AGENTS.md

  ## Commands

  - Run the tests with `mix test` before every commit.
  - Format with `mix format`.
  """

  @gemini """
  # GEMINI.md

  - Run the tests with `mix test` before every commit.
  - Never edit the files under `priv/static` by hand: they are built.
  """

  @copilot "Keep every public function documented with a `@doc` of its own.\n"

  @fixture %{
    "CLAUDE.md" => @claude,
    "GEMINI.md" => @gemini,
    ".github/copilot-instructions.md" => @copilot,
    "pkg/CLAUDE.md" => "Run this package's tests from `pkg/`, never from the root.\n",
    ".github/instructions/elixir.instructions.md" => """
    ---
    applyTo: "**/*.ex,**/*.exs"
    description: Elixir style
    excludeAgent: code-review
    ---
    Pipe into a function only when the first argument is the subject.
    """,
    ".github/instructions/all.instructions.md" => """
    ---
    applyTo: "**"
    ---
    Write commit messages in the present tense.
    """,
    ".cursor/rules/style.mdc" => """
    ---
    description: House style
    globs: lib/**/*.ex, test/**/*.exs
    alwaysApply: false
    ---
    Prefer pattern matching in function heads.
    """,
    ".cursor/rules/always.mdc" => "---\nalwaysApply: true\n---\nAnswer in English.\n",
    ".cursor/rules/Docs Guide.mdc" => """
    ---
    description: How the docs are written
    ---
    Docs are plain Markdown, one sentence per line.
    """,
    ".cursorrules" => "Never commit a secret.\n",
    "pkg/.cursor/rules/lint.mdc" => """
    ---
    globs: src/**/*.ts, *.tsx
    ---
    Use the package's own lint configuration.
    """,
    "pkg/.cursor/rules/always.mdc" => "---\nalwaysApply: true\n---\nThis package is TypeScript.\n"
  }

  describe "the source" do
    test "each kind of file is proposed, with its notes, as an AGENTS.md beside it or a rule",
         ctx do
      write_all!(ctx.workspace, @fixture)

      %{proposals: proposals, skipped: skipped} = Instructions.survey(ctx.workspace, ctx.opts)

      assert Enum.map(proposals, &{&1.target, &1.path}) == [
               {:workspace, "AGENTS.md"},
               {:workspace, "pkg/AGENTS.md"},
               {:repo, "rules/all.md"},
               {:repo, "rules/always.md"},
               {:repo, "rules/cursorrules.md"},
               {:repo, "rules/docs-guide.md"},
               {:repo, "rules/elixir.md"},
               {:repo, "rules/pkg-always.md"},
               {:repo, "rules/pkg-lint.md"},
               {:repo, "rules/style.md"}
             ]

      assert skipped == []
      [root, pkg | rules] = proposals
      rules = Map.new(rules, &{&1.path, &1})

      # The root's: CLAUDE.md's substance, then what GEMINI.md and Copilot's file add, each
      # unit said once; the line importing AGENTS.md itself left out, the title renamed.
      assert root.content == """
             # AGENTS.md

             This repository is a small Elixir service that answers questions about invoices.

             ## Commands

             - Run the tests with `mix test` before every commit.
             - Format with `mix format`.

             - Never edit the files under `priv/static` by hand: they are built.

             Keep every public function documented with a `@doc` of its own.
             """

      assert root.source == "CLAUDE.md"
      assert root.source_hash == sha256(@claude)

      assert root.also_from == [
               %{source: "GEMINI.md", source_hash: sha256(@gemini)},
               %{source: ".github/copilot-instructions.md", source_hash: sha256(@copilot)}
             ]

      assert root.notes == [
               "The line `@AGENTS.md` of CLAUDE.md is left out: it imports the file it would be written into.",
               "The title `# CLAUDE.md` of CLAUDE.md is written `# AGENTS.md`.",
               "The title `# GEMINI.md` of GEMINI.md is left out: what it adds goes after what is there.",
               "1 paragraph or list item of GEMINI.md is left out: it is said already."
             ]

      assert pkg.content == "Run this package's tests from `pkg/`, never from the root.\n"
      assert pkg.source == "pkg/CLAUDE.md"
      assert pkg.also_from == []

      # Rules: Decision 809's front matter, from the root.
      assert rules["rules/style.md"].content == """
             ---
             description: "House style"
             globs: ["lib/**/*.ex", "test/**/*.exs"]
             ---
             Prefer pattern matching in function heads.
             """

      assert rules["rules/always.md"].content ==
               "---\nalwaysApply: true\n---\nAnswer in English.\n"

      assert rules["rules/docs-guide.md"].content == """
             ---
             description: "How the docs are written"
             ---
             Docs are plain Markdown, one sentence per line.
             """

      assert rules["rules/docs-guide.md"].notes == [
               "Named docs-guide: a rule's name is lowercase letters, digits and dashes."
             ]

      assert rules["rules/cursorrules.md"].content ==
               "---\nalwaysApply: true\n---\nNever commit a secret.\n"

      assert rules["rules/cursorrules.md"].source == ".cursorrules"

      assert rules["rules/elixir.md"].content == """
             ---
             description: "Elixir style"
             globs: ["**/*.ex", "**/*.exs"]
             ---
             Pipe into a function only when the first argument is the subject.
             """

      assert rules["rules/elixir.md"].notes == [
               "excludeAgent is not carried: a rule's front matter is description, globs and alwaysApply.",
               "applyTo is written as globs."
             ]

      assert rules["rules/all.md"].content ==
               "---\nalwaysApply: true\n---\nWrite commit messages in the present tense.\n"

      # A nested rule's globs from the root; its always, once the session works under it.
      assert rules["rules/pkg-lint.md"].content == """
             ---
             globs: ["pkg/src/**/*.ts", "pkg/**/*.tsx"]
             ---
             Use the package's own lint configuration.
             """

      assert rules["rules/pkg-always.md"].content ==
               ~s(---\nglobs: ["pkg/**"]\n---\nThis package is TypeScript.\n)

      assert [note] = rules["rules/pkg-always.md"].notes
      assert note =~ "alwaysApply under pkg/ applied once the session worked there"

      for proposal <- proposals,
          do:
            assert(
              proposal.source_hash ==
                sha256(File.read!(Path.join(ctx.workspace, proposal.source)))
            )
    end

    test "the same files give the same proposals, byte for byte", ctx do
      write_all!(ctx.workspace, @fixture)

      assert Instructions.survey(ctx.workspace, ctx.opts) ==
               Instructions.survey(ctx.workspace, ctx.opts)
    end

    test "what an AGENTS.md already says is not proposed again, and what is new is added after it, under its heading",
         ctx do
      write_all!(ctx.workspace, %{
        "AGENTS.md" => """
        # Agents

        ## Commands

        - run the tests with mix test before every commit
        - Format with `mix format`.
        """,
        "CLAUDE.md" => """
        # Project

        ## Commands

        - Run the tests with `mix test` before every commit.
        - Format with `mix format`.

        ## Testing

        Every test that starts a session stops it when it is done.
        """
      })

      assert [proposal] = Instructions.proposals(ctx.workspace, ctx.opts)

      assert proposal.content == """
             # Agents

             ## Commands

             - run the tests with mix test before every commit
             - Format with `mix format`.

             ## Testing

             Every test that starts a session stops it when it is done.
             """

      assert proposal.notes == [
               "2 paragraphs or list items of CLAUDE.md are left out: they are said already."
             ]

      # Through the plan: an addition to the file that is there, asked as any write.
      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert item.status == :changed
      assert item.question == :write
      assert item.diff =~ "+ ## Testing"
      refute item.diff =~ ~r/^- /m
    end

    test "a file whose every word is said already proposes nothing, and says so", ctx do
      write_all!(ctx.workspace, %{
        "AGENTS.md" => "Keep every change small and reviewed.\n",
        ".agents/AGENTS.md" => "Use the project's own scripts.\n",
        "CLAUDE.md" => "Keep every change small and reviewed.\n\nUse the project's own scripts.\n"
      })

      assert %{proposals: [], skipped: [skipped]} = Instructions.survey(ctx.workspace, ctx.opts)

      assert skipped == %{
               source: "CLAUDE.md",
               reason: "everything it says is in AGENTS.md or .agents/AGENTS.md already"
             }
    end

    test "a CLAUDE.md that is AGENTS.md under another name, or links out, gives nothing", ctx do
      write_all!(ctx.workspace, %{"AGENTS.md" => "Be brief.\n"})
      :ok = File.ln_s("AGENTS.md", Path.join(ctx.workspace, "CLAUDE.md"))
      write_all!(ctx.base, %{"elsewhere.md" => "A secret rule.\n"})
      File.mkdir_p!(Path.join(ctx.workspace, "pkg"))

      :ok =
        File.ln_s(Path.join(ctx.base, "elsewhere.md"), Path.join(ctx.workspace, "pkg/CLAUDE.md"))

      assert %{proposals: [], skipped: skipped} = Instructions.survey(ctx.workspace, ctx.opts)

      assert skipped == [
               %{
                 source: "CLAUDE.md",
                 reason: "it is AGENTS.md under another name, so there is nothing to add"
               },
               %{
                 source: "pkg/CLAUDE.md",
                 reason: "it is a link to outside the workspace, and is not read"
               }
             ]
    end

    test "files no tool reads there are listed as skipped, saying why", ctx do
      write_all!(ctx.workspace, %{
        "pkg/.github/copilot-instructions.md" => "x\n",
        "pkg/.cursorrules" => "x\n",
        "pkg/.github/instructions/a.instructions.md" => "x\n",
        ".cursor/rules/deeper/a.mdc" => "x\n",
        ".cursor/rules/empty.mdc" => "---\nalwaysApply: true\n---\n",
        "GEMINI.md" => "  \n",
        "node_modules/lib/CLAUDE.md" => "not ours\n",
        "ignored/CLAUDE.md" => "not ours either\n",
        ".gitignore" => "ignored/\n"
      })

      assert %{proposals: [], skipped: skipped} = Instructions.survey(ctx.workspace, ctx.opts)

      assert skipped == [
               %{
                 source: ".cursor/rules/deeper/a.mdc",
                 reason:
                   "not onboarded: onboarding brings in the rules directly in .cursor/rules, not in a folder under it"
               },
               %{
                 source: ".cursor/rules/empty.mdc",
                 reason: "it has nothing but its front matter"
               },
               %{source: "GEMINI.md", reason: "it is empty"},
               %{
                 source: "pkg/.cursorrules",
                 reason: "not onboarded: Cursor reads .cursorrules at the repository root only"
               },
               %{
                 source: "pkg/.github/copilot-instructions.md",
                 reason: "not onboarded: Copilot reads its file at the repository root only"
               },
               %{
                 source: "pkg/.github/instructions/a.instructions.md",
                 reason:
                   "not onboarded: Copilot reads .github/instructions at the repository root only"
               }
             ]
    end

    test "two rules of one name are told apart, and a rule with nothing that says when it applies says so",
         ctx do
      write_all!(ctx.workspace, %{
        ".cursor/rules/style.mdc" => "---\nalwaysApply: true\n---\nOne.\n",
        ".github/instructions/style.instructions.md" => "Two.\n"
      })

      proposals = Instructions.proposals(ctx.workspace, ctx.opts)
      cursor = Enum.find(proposals, &(&1.source == ".cursor/rules/style.mdc"))
      copilot = Enum.find(proposals, &(&1.source == ".github/instructions/style.instructions.md"))
      assert cursor.path == "rules/style.md"
      assert copilot.path == "rules/style-2.md"
      assert copilot.content == "Two.\n"

      assert copilot.notes == [
               "It has no alwaysApply, globs or description, so a session never joins it by itself: give it one, or leave it out.",
               "Named style-2: style is .cursor/rules/style.mdc's."
             ]
    end

    test "an AGENTS.md with Windows line endings keeps them, and the diff shows only what is added",
         ctx do
      write_all!(ctx.workspace, %{
        "AGENTS.md" => "# Agents\r\n\r\nKeep it small.\r\n",
        "CLAUDE.md" => "Keep it small.\r\n\r\nAsk before deleting anything.\r\n"
      })

      assert [proposal] = Instructions.proposals(ctx.workspace, ctx.opts)

      assert proposal.content ==
               "# Agents\r\n\r\nKeep it small.\r\n\r\nAsk before deleting anything.\r\n"

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert item.diff =~ "+ Ask before deleting anything."
      refute item.diff =~ "- Keep it small."
    end
  end

  describe "Claude Code's other names, and the person's own files" do
    test "a repository's .claude/CLAUDE.md is added to the root's AGENTS.md after CLAUDE.md",
         ctx do
      write_all!(ctx.workspace, %{
        "CLAUDE.md" => "Run the tests with `mix test` before every commit.\n",
        ".claude/CLAUDE.md" => """
        # CLAUDE.md

        @../AGENTS.md

        Ask before deleting a file under `priv/`, and see @docs/deleting.md for why.
        """
      })

      assert [proposal] = Instructions.proposals(ctx.workspace, ctx.opts)
      assert proposal.target == :workspace
      assert proposal.path == "AGENTS.md"
      assert proposal.source == "CLAUDE.md"
      assert [%{source: ".claude/CLAUDE.md"}] = proposal.also_from

      assert proposal.content == """
             Run the tests with `mix test` before every commit.

             Ask before deleting a file under `priv/`, and see @docs/deleting.md for why.
             """

      assert proposal.notes == [
               "The line `@../AGENTS.md` of .claude/CLAUDE.md is left out: it imports the file it would be written into.",
               "The title `# CLAUDE.md` of .claude/CLAUDE.md is left out: what it adds goes after what is there.",
               "An @ import in .claude/CLAUDE.md is read from beside AGENTS.md once it is there, not from beside .claude/CLAUDE.md."
             ]
    end

    test "CLAUDE.local.md is the person's own: never proposed, and says how to keep it", ctx do
      write_all!(ctx.workspace, %{
        "CLAUDE.local.md" => "My own notes.\n",
        "pkg/CLAUDE.local.md" => "x\n"
      })

      reason =
        "not onboarded: CLAUDE.local.md is your own and usually not committed, so it is not " <>
          "proposed into a file that is; move what it says into your config directory's " <>
          "AGENTS.md by hand, or keep it"

      assert %{proposals: [], skipped: skipped} = Instructions.survey(ctx.workspace, ctx.opts)

      assert skipped == [
               %{source: "CLAUDE.local.md", reason: reason},
               %{source: "pkg/CLAUDE.local.md", reason: reason}
             ]
    end

    test "the config directory's CLAUDE.md and GEMINI.md and ~/.claude/CLAUDE.md go into the person's own AGENTS.md",
         ctx do
      config = Path.join(ctx.home, ".config/troupe")
      opts = Keyword.put(ctx.opts, :config_dir, config)

      write_all!(config, %{
        "AGENTS.md" => "Answer briefly.\n",
        "CLAUDE.md" => "Answer briefly.\n\nAsk before deleting anything you did not create.\n",
        "GEMINI.md" => "Prefer small commits over large ones, in every repository.\n"
      })

      write_all!(ctx.home, %{
        ".claude/CLAUDE.md" => "# CLAUDE.md\n\nNever push to main without asking first.\n"
      })

      assert [proposal] = Instructions.proposals(ctx.workspace, opts)
      assert proposal.target == :user
      assert proposal.path == "AGENTS.md"
      assert proposal.source == "~/.config/troupe/CLAUDE.md"

      assert Enum.map(proposal.also_from, & &1.source) == [
               "~/.config/troupe/GEMINI.md",
               "~/.claude/CLAUDE.md"
             ]

      assert proposal.content == """
             Answer briefly.

             Ask before deleting anything you did not create.

             Prefer small commits over large ones, in every repository.

             Never push to main without asking first.
             """

      # Written into the config directory with its record there, never the repository,
      # and a second run proposes nothing.
      assert %{proposals: [item], refused: []} = Onboard.plan(ctx.workspace, opts)
      assert item.shown =~ "AGENTS.md"
      assert item.question == :write
      assert {:ok, %{action: :replaced}} = Onboard.accept(item, ctx.workspace, opts)

      assert File.read!(Path.join(config, "AGENTS.md")) == proposal.content
      refute File.exists?(Path.join(ctx.workspace, "AGENTS.md"))
      refute File.exists?(Path.join(ctx.workspace, ".troupe"))

      assert %{"files" => %{"AGENTS.md" => %{"imported_from" => "~/.config/troupe/CLAUDE.md"}}} =
               Jason.decode!(File.read!(Path.join(config, "onboarded.json")))

      assert %{proposals: [], skipped: skipped} = Onboard.plan(ctx.workspace, opts)

      assert Enum.map(skipped, & &1.source) == [
               "~/.claude/CLAUDE.md",
               "~/.config/troupe/CLAUDE.md",
               "~/.config/troupe/GEMINI.md"
             ]

      assert Enum.all?(skipped, &(&1.reason =~ "everything it says is in"))
    end

    test "a config directory outside the home directory is skipped; ~/.claude/CLAUDE.md still goes in",
         ctx do
      write_all!(ctx.config, %{"CLAUDE.md" => "Answer briefly.\n"})
      write_all!(ctx.home, %{".claude/CLAUDE.md" => "Never push to main without asking first.\n"})

      assert %{proposals: [proposal], skipped: [skipped]} =
               Instructions.survey(ctx.workspace, ctx.opts)

      assert proposal.source == "~/.claude/CLAUDE.md"
      assert proposal.also_from == []
      assert proposal.content == "Never push to main without asking first.\n"

      assert skipped.reason ==
               "not onboarded: it is not in your home directory, where onboarding takes your own files from"

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert {:ok, %{action: :created}} = Onboard.accept(item, ctx.workspace, ctx.opts)
      assert File.read!(Path.join(ctx.config, "AGENTS.md")) == proposal.content
    end
  end

  describe "onboarding them" do
    test "every proposal written with its provenance and version, and a second run proposes nothing",
         ctx do
      write_all!(ctx.workspace, @fixture)

      assert %{proposals: items, refused: []} = Onboard.plan(ctx.workspace, ctx.opts)
      assert length(items) == 10

      # The new AGENTS.md files are their own question; the rest are ordinary writes.
      assert for(%{question: :create_agents_md} = i <- items, do: i.shown) == [
               "AGENTS.md",
               "pkg/AGENTS.md"
             ]

      Enum.each(
        items,
        &({:ok, %{action: :created}} = Onboard.accept(&1, ctx.workspace, ctx.opts))
      )

      assert File.read!(Path.join(ctx.workspace, "AGENTS.md")) =~ "# AGENTS.md\n"
      assert File.read!(Path.join(ctx.workspace, "pkg/AGENTS.md")) =~ "never from the root"

      manifest = Jason.decode!(File.read!(Path.join(ctx.workspace, ".troupe/onboarded.json")))
      assert manifest["version"] == 1
      assert manifest["onboarding"] == Onboard.version()

      version = Onboard.version()

      assert %{
               "AGENTS.md" => %{
                 "imported_from" => "CLAUDE.md",
                 "imported_hash" => claude_hash,
                 "imported_at" => @now,
                 "imported_version" => ^version,
                 "imported_also" => [
                   %{"from" => ".github/copilot-instructions.md"},
                   %{"from" => "GEMINI.md"}
                 ]
               },
               "pkg/AGENTS.md" => %{"imported_from" => "pkg/CLAUDE.md"}
             } = manifest["workspace"]

      assert claude_hash == sha256(@claude)
      assert manifest["files"] == %{}

      rule = File.read!(Path.join(ctx.workspace, ".troupe/rules/style.md"))

      assert rule == """
             ---
             description: "House style"
             globs: ["lib/**/*.ex", "test/**/*.exs"]
             imported_from: ".cursor/rules/style.mdc"
             imported_hash: "#{sha256(@fixture[".cursor/rules/style.mdc"])}"
             imported_at: "#{@now}"
             imported_version: #{version}
             ---
             Prefer pattern matching in function heads.
             """

      # Nothing changed: nothing proposed, and the files already said are named.
      assert %{proposals: [], unchanged: 8, skipped: skipped} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert %{source: "CLAUDE.md", reason: "everything it says is in AGENTS.md already"} in skipped

      # `troupe instructions check` sees them, and nothing has drifted.
      check = [executable?: fn _ -> true end, config_dir: ctx.config, home: ctx.home]
      assert {json, 0} = Check.run(ctx.workspace, [json: true] ++ check)

      onboarded = for f <- Jason.decode!(json)["onboarded"], do: f["imported_from"]
      assert "CLAUDE.md" in onboarded
      assert ".cursor/rules/style.mdc" in onboarded
    end

    test "a change to one of the files is drift on the AGENTS.md, and proposes only what it adds",
         ctx do
      write_all!(ctx.workspace, %{
        ".git/HEAD" => "ref: refs/heads/main\n",
        "CLAUDE.md" => @claude,
        "GEMINI.md" => @gemini
      })

      %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)

      File.write!(Path.join(ctx.workspace, "GEMINI.md"), @gemini <> "- Answer in English.\n")

      check = [executable?: fn _ -> true end, config_dir: ctx.config, home: ctx.home]
      assert {out, 1} = Check.run(ctx.workspace, check)

      assert out =~
               "AGENTS.md:1: drift: imported with `GEMINI.md`, which has changed since; " <>
                 "`troupe onboard` shows what changed\n"

      assert %{proposals: [changed]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert changed.status == :changed
      assert changed.question == :write
      assert changed.was == "CLAUDE.md"

      added =
        for "+" <> line <- String.split(changed.diff, "\n"), String.trim(line) != "", do: line

      assert added == [" - Answer in English."]
    end

    test "a declined new AGENTS.md leaves nothing behind and is not asked about again", ctx do
      write_all!(ctx.workspace, %{"CLAUDE.md" => "Be brief.\n"})

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert item.question == :create_agents_md
      assert :ok = Onboard.decline(item, ctx.opts)

      refute File.exists?(Path.join(ctx.workspace, "AGENTS.md"))
      refute File.exists?(Path.join(ctx.workspace, ".troupe"))
      assert %{proposals: [], declined: 1} = Onboard.plan(ctx.workspace, ctx.opts)
    end
  end

  # opencode's `instructions`: more files it joins into every prompt beside AGENTS.md, each
  # a path or a glob from the root. On the chunk's tip they gave no proposal at all, and
  # the onboarding rules were version 1.
  describe "opencode's instructions" do
    test "each file it names here goes into the root's AGENTS.md, or is a rule when its own globs scope it; the rest is skipped, saying why",
         ctx do
      write_all!(ctx.workspace, %{
        "opencode.json" => """
        {
          "$schema": "https://opencode.ai/config.json",
          "instructions": [
            "CONTRIBUTING.md",
            "docs/*.md",
            "rules/ts.md",
            "CLAUDE.md",
            "packages/*/AGENTS.md",
            "https://example.com/shared-rules.md",
            "~/rules.md",
            "../outside.md",
            "missing/*.md",
            "empty.md",
            7
          ]
        }
        """,
        "CLAUDE.md" => "Run the tests with `mix test` before every commit.\n",
        "CONTRIBUTING.md" => "# Contributing\n\nOpen a pull request against `main`.\n",
        "docs/review.md" => "Ask for one review.\n",
        "docs/style.md" => "---\ndescription: Docs style\n---\nOne sentence per line.\n",
        "rules/ts.md" => "---\nglobs: \"src/**/*.ts\"\n---\nNo `any`.\n",
        "packages/web/AGENTS.md" => "Web.\n",
        "empty.md" => "\n"
      })

      File.write!(Path.join(ctx.base, "outside.md"), "Not the workspace's.\n")

      assert Onboard.version() == 2
      %{proposals: proposals, skipped: skipped} = Instructions.survey(ctx.workspace, ctx.opts)

      assert Enum.map(proposals, &{&1.target, &1.path, &1.source}) == [
               {:workspace, "AGENTS.md", "CLAUDE.md"},
               {:repo, "rules/ts.md", "rules/ts.md"}
             ]

      [agents, rule] = proposals

      assert agents.content == """
             Run the tests with `mix test` before every commit.

             # Contributing

             Open a pull request against `main`.

             Ask for one review.

             One sentence per line.
             """

      assert agents.also_from ==
               for(
                 file <- ~w(CONTRIBUTING.md docs/review.md docs/style.md),
                 do: %{
                   source: file,
                   source_hash: sha256(File.read!(Path.join(ctx.workspace, file)))
                 }
               )

      named = "is named in opencode.json's instructions, which opencode joins into every prompt"

      assert agents.notes == [
               "CONTRIBUTING.md #{named}: what it says is added to AGENTS.md.",
               "docs/review.md #{named}: what it says is added to AGENTS.md.",
               "docs/style.md #{named}: what it says is added to AGENTS.md.",
               "The front matter of docs/style.md is left out: nothing in it scopes the file, and AGENTS.md has none."
             ]

      assert rule.content == ~s(---\nglobs: ["src/**/*.ts"]\n---\nNo `any`.\n)

      assert rule.notes == [
               "rules/ts.md #{named}, and its own globs scope it: it joins once a file they match is read or edited."
             ]

      not_onboarded = "not onboarded: instructions names"
      outside = "which is outside the workspace; onboarding takes only the workspace's files"

      assert skipped == [
               %{source: "empty.md", reason: "it is empty"},
               %{source: "opencode.json", reason: "#{not_onboarded} ../outside.md, #{outside}"},
               %{source: "opencode.json", reason: "#{not_onboarded} 7, which is not a path"},
               %{
                 source: "opencode.json",
                 reason:
                   "#{not_onboarded} CLAUDE.md, which is onboarded on its own, as the other tool's file it is"
               },
               %{
                 source: "opencode.json",
                 reason:
                   "#{not_onboarded} https://example.com/shared-rules.md, which opencode fetches " <>
                     "from the web; onboarding takes only the workspace's files"
               },
               %{
                 source: "opencode.json",
                 reason: "#{not_onboarded} missing/*.md: no file here matches it"
               },
               %{
                 source: "opencode.json",
                 reason:
                   "#{not_onboarded} packages/web/AGENTS.md, an AGENTS.md, which Troupe reads itself, in its directory"
               },
               %{source: "opencode.json", reason: "#{not_onboarded} ~/rules.md, #{outside}"}
             ]
    end

    test "a workspace with only opencode's instructions is found, onboarded once, and drifts when a file changes",
         ctx do
      write_all!(ctx.workspace, %{
        ".git/HEAD" => "ref: refs/heads/main\n",
        "opencode.jsonc" => """
        {
          // The house rules, shared with the other tools.
          "instructions": ["docs/house-rules.md"]
        }
        """,
        "docs/house-rules.md" => "Every file you write starts with a licence header.\n"
      })

      assert Instructions.found?(ctx.workspace)

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert item.question == :create_agents_md
      assert item.proposal.source == "docs/house-rules.md"
      {:ok, %{action: :created}} = Onboard.accept(item, ctx.workspace, ctx.opts)

      assert File.read!(Path.join(ctx.workspace, "AGENTS.md")) ==
               "Every file you write starts with a licence header.\n"

      manifest = Jason.decode!(File.read!(Path.join(ctx.workspace, ".troupe/onboarded.json")))

      assert %{"imported_from" => "docs/house-rules.md", "imported_version" => 2} =
               manifest["workspace"]["AGENTS.md"]

      assert %{proposals: [], skipped: [again]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert again.reason == "everything it says is in AGENTS.md already"

      File.write!(Path.join(ctx.workspace, "docs/house-rules.md"), "Use tabs.\n")
      check = [executable?: fn _ -> true end, config_dir: ctx.config, home: ctx.home]
      assert {out, 1} = Check.run(ctx.workspace, check)
      assert out =~ "AGENTS.md:1: drift: "
    end
  end

  describe "the writer's AGENTS.md" do
    test "only an AGENTS.md, in a directory of the workspace that is there and not hidden", ctx do
      write_all!(ctx.workspace, %{
        "CLAUDE.md" => "x\n",
        "pkg/x.txt" => "x\n",
        ".agents/x.txt" => "x\n"
      })

      outside = Path.join(ctx.base, "outside")
      File.mkdir_p!(outside)
      :ok = File.ln_s(outside, Path.join(ctx.workspace, "linked"))
      :ok = File.ln_s(Path.join(ctx.workspace, ".agents"), Path.join(ctx.workspace, "dots"))

      refusals =
        for path <- [
              "CLAUDE.md",
              "pkg/README.md",
              ".agents/AGENTS.md",
              ".troupe/AGENTS.md",
              "../AGENTS.md",
              "/AGENTS.md",
              "missing/AGENTS.md",
              "linked/AGENTS.md",
              "dots/AGENTS.md"
            ] do
          proposal = %{
            target: :workspace,
            path: path,
            content: "x\n",
            source: "CLAUDE.md",
            source_hash: sha256("x\n"),
            notes: []
          }

          assert {:error, reason} = Onboard.write(proposal, ctx.workspace, ctx.opts)
          reason
        end

      assert [
               "`CLAUDE.md` is not a file onboarding writes into the workspace" <> _,
               "`pkg/README.md` is not a file onboarding writes into the workspace" <> _,
               "`.agents/AGENTS.md` is not a file onboarding writes into the workspace" <> _,
               "`.troupe/AGENTS.md` is not a file onboarding writes into the workspace" <> _,
               "`../AGENTS.md` has an empty, `.` or `..` part",
               "`/AGENTS.md` is not relative: an AGENTS.md's path is relative to the workspace",
               "`missing/AGENTS.md`: there is no such directory in the workspace" <> _,
               "`linked/AGENTS.md` resolves to " <> linked,
               "`dots/AGENTS.md` resolves into a hidden directory" <> _
             ] = refusals

      assert linked =~ "outside the workspace"
      refute File.exists?(Path.join(ctx.workspace, "AGENTS.md"))
      refute File.exists?(Path.join(ctx.workspace, ".troupe"))
      assert File.ls!(outside) == []

      # A `.troupe` that links out takes no record, so no AGENTS.md either.
      :ok = File.ln_s(outside, Path.join(ctx.workspace, ".troupe"))

      assert {:error, reason} =
               Onboard.write(
                 %{
                   target: :workspace,
                   path: "pkg/AGENTS.md",
                   content: "x\n",
                   source: "CLAUDE.md",
                   source_hash: sha256("x\n"),
                   notes: []
                 },
                 ctx.workspace,
                 ctx.opts
               )

      assert reason =~ "outside the workspace's .troupe/"
      refute File.exists?(Path.join(ctx.workspace, "pkg/AGENTS.md"))
    end
  end

  describe "versions" do
    test "a file written by older rules is left alone when the new would write it the same, and offered when not",
         ctx do
      write_all!(ctx.workspace, %{".cursor/rules/a.mdc" => "---\nalwaysApply: true\n---\nA.\n"})
      %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)

      file = Path.join(ctx.workspace, ".troupe/rules/a.md")
      current = "imported_version: #{Onboard.version()}\n"
      older = String.replace(File.read!(file), current, "imported_version: 0\n")
      File.write!(file, older)

      # Older rules, the same file: nothing to show.
      assert %{proposals: [], unchanged: 1} = Onboard.plan(ctx.workspace, ctx.opts)

      # Older rules and a file the new would write otherwise (say the person edited it):
      # offered once, as a diff.
      File.write!(file, String.replace(older, "A.\n", "A, as we say it.\n"))
      assert %{proposals: [offered]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert offered.diff =~ "- A, as we say it."
      assert offered.diff =~ "+ " <> current

      # With this build's version, the person's edit stands.
      File.write!(file, String.replace(File.read!(file), "imported_version: 0\n", current))

      assert %{proposals: [], unchanged: 1} = Onboard.plan(ctx.workspace, ctx.opts)
    end

    test "a workspace onboarded under older rules is an outdated finding until troupe onboard stamps it",
         ctx do
      write_all!(ctx.workspace, %{
        ".git/HEAD" => "ref: refs/heads/main\n",
        "CLAUDE.md" => "Be brief.\n"
      })

      assert Onboard.onboarded_version(ctx.workspace) == nil

      %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)
      assert Onboard.onboarded_version(ctx.workspace) == Onboard.version()

      manifest = Path.join(ctx.workspace, ".troupe/onboarded.json")

      File.write!(
        manifest,
        String.replace(
          File.read!(manifest),
          ~s("onboarding": #{Onboard.version()}),
          ~s("onboarding": 0)
        )
      )

      assert Onboard.onboarded_version(ctx.workspace) == 0

      check = [executable?: fn _ -> true end, config_dir: ctx.config, home: ctx.home]
      assert {out, 1} = Check.run(ctx.workspace, check)

      assert out =~
               ".troupe/onboarded.json:3: outdated: onboarded under version 0 of the onboarding " <>
                 "rules, and this build's are version #{Onboard.version()}: `troupe onboard` " <>
                 "shows what they would write now\n"

      assert :ok = Onboard.stamp(ctx.workspace)
      assert Onboard.onboarded_version(ctx.workspace) == Onboard.version()
      assert {_out, 0} = Check.run(ctx.workspace, check)

      # One file's write does not raise the workspace's version; a manifest from before
      # versions is version 0.
      File.write!(manifest, ~s({"version": 1, "files": {}}))
      assert Onboard.onboarded_version(ctx.workspace) == 0
      File.write!(Path.join(ctx.workspace, "CLAUDE.md"), "Be briefer.\n")
      %{proposals: [again]} = Onboard.plan(ctx.workspace, ctx.opts)
      {:ok, _} = Onboard.accept(again, ctx.workspace, ctx.opts)
      assert Onboard.onboarded_version(ctx.workspace) == 0
    end
  end

  defp write_all!(dir, files) do
    for {relative, contents} <- files do
      path = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
