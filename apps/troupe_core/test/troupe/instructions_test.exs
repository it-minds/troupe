defmodule Troupe.InstructionsTest do
  @moduledoc """
  The instruction files a repository carries (Decisions 706, 798, 806, 809 and 828): which
  are read and in what order, the directories the conversation worked in, the other tools'
  files listed as skipped and why, Copilot's file below the root, a file that cannot be
  read, what an `@import` brings and where it stops, `.troupe/rules` and when each joins,
  how the budget is shared with the nearest kept whole, where the repository root is,
  and how the digest follows the content. The loader alone; a real session's prompt is
  `instructions_prompt_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Instructions
  alias Troupe.LLM.{Message, ToolResult, ToolUse}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-instr-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, repo: Path.expand(repo)}
  end

  test "the root's file, then one per directory down to the workspace, nearest last", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "root rule")
    write!(repo, "frontend/AGENTS.md", "frontend rule")
    write!(repo, "frontend/app/AGENTS.md", "app rule")
    write!(repo, "backend/AGENTS.md", "not on the path")

    loaded = Instructions.load(Path.join(repo, "frontend/app"), config())

    assert files(loaded, repo) == [
             {:root, "AGENTS.md"},
             {:nested, "frontend/AGENTS.md"},
             {:nested, "frontend/app/AGENTS.md"}
           ]

    assert List.last(loaded.files).scope == :brief

    assert loaded.used ==
             String.length("root rule") + String.length("frontend rule") +
               String.length("app rule")

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "# Instruction files"
    assert [_head, root, frontend, app] = String.split(prompt, "Contents of ")
    assert root =~ "(repository root):\nroot rule"
    assert frontend =~ "(nearer: frontend/):\nfrontend rule"
    assert app =~ "(nearer: frontend/app/):\napp rule"
    refute prompt =~ "not on the path"
  end

  test "an .agents/AGENTS.md is read at its directory's scope, before that directory's own file",
       %{repo: repo} do
    write!(repo, ".agents/AGENTS.md", "the root's .agents")
    write!(repo, "AGENTS.md", "the root's own")
    write!(repo, "web/.agents/AGENTS.md", "web's .agents")
    write!(repo, "api/.agents/AGENTS.md", "not on the way")

    loaded = Instructions.load(repo, config(), ["web/a.ts"])

    assert files(loaded, repo) == [
             {:root, ".agents/AGENTS.md"},
             {:root, "AGENTS.md"},
             {:nested, "web/.agents/AGENTS.md"}
           ]

    assert [
             %{scope: :root, status: :whole, reason: nil, skipped: []},
             %{scope: :root, status: :whole, skipped: []},
             %{scope: :nested, where: "web", status: :whole}
           ] = Enum.reject(loaded.files, &(&1.scope == :brief))

    prompt = Instructions.to_prompt(loaded)
    assert [_head, agents, own, web] = String.split(prompt, "Contents of ")
    assert agents =~ "(repository root):\nthe root's .agents"
    assert own =~ "(repository root):\nthe root's own"
    assert web =~ "(nearer: web/):\nweb's .agents"
    refute prompt =~ "not on the way"

    assert [
             %{"scope" => "root", "path" => path, "status" => "whole", "reason" => nil},
             %{"scope" => "root"},
             %{"scope" => "nested"},
             %{"scope" => "brief"}
           ] = Instructions.provenance(loaded)["files"]

    assert path == Path.join(repo, ".agents/AGENTS.md")
  end

  # A session that works on a file under `.agents/` walks `.agents` as a directory of its
  # own; its `AGENTS.md` is the parent's `.agents/AGENTS.md`, read once, there.
  test "an .agents/AGENTS.md is read once when the session works under .agents/", %{repo: repo} do
    write!(repo, ".agents/AGENTS.md", "the root's .agents")
    write!(repo, ".agents/skills/x/SKILL.md", "---\nname: x\n---\nA skill.")
    write!(repo, "web/.agents/AGENTS.md", "web's .agents")

    loaded =
      Instructions.load(repo, config(), [".agents/skills/x/SKILL.md", "web/.agents/notes.md"])

    assert files(loaded, repo) == [
             {:root, ".agents/AGENTS.md"},
             {:nested, "web/.agents/AGENTS.md"}
           ]

    assert loaded.used == String.length("the root's .agents") + String.length("web's .agents")
  end

  test "an .agents/AGENTS.md really outside the repository, through a linked .agents, is not read",
       %{base: base, repo: repo} do
    write!(base, "elsewhere/AGENTS.md", "a stand-in for a private file")
    File.ln_s!(Path.join(base, "elsewhere"), Path.join(repo, ".agents"))
    write!(repo, "AGENTS.md", "root rule")

    loaded = Instructions.load(repo, config())

    assert [
             %{
               scope: :root,
               status: :outside,
               chars: 0,
               hash: nil,
               reason: "not read: outside the repository"
             },
             %{scope: :root, status: :whole, text: "root rule"},
             %{scope: :brief}
           ] = loaded.files

    assert hd(loaded.files).path == Path.join(repo, ".agents/AGENTS.md")
    refute Instructions.to_prompt(loaded) =~ "private"
  end

  # Decision 828: other tools' files are brought in once, by `troupe onboard`, and no
  # longer read. Each one found is listed as skipped, saying so, and nothing of it is read.
  test "CLAUDE.md, GEMINI.md, Copilot's file and Cursor's rules are listed as skipped, " <>
         "never read",
       %{repo: repo} do
    write!(repo, "CLAUDE.md", "claude's")
    write!(repo, "GEMINI.md", "gemini's")
    write!(repo, ".github/copilot-instructions.md", "copilot's")
    write!(repo, ".cursorrules", "legacy cursor")
    write!(repo, ".cursor/rules/style.mdc", "---\nalwaysApply: true\n---\ncursor's")
    write!(repo, ".cursor/rules/notes.txt", "not a rule")
    write!(repo, "lib/AGENTS.md", "nested agents")
    write!(repo, "lib/CLAUDE.md", "nested claude")
    write!(repo, "lib/.cursor/rules/lib.mdc", "---\nalwaysApply: true\n---\nnested cursor")
    write!(repo, "lib/.cursorrules", "a nested legacy file, never read by anyone")

    loaded = Instructions.load(repo, config(), ["lib/a.ex"])
    onboard = "not read: run troupe onboard"

    assert files(loaded, repo) == [
             {:root, "CLAUDE.md"},
             {:root, "GEMINI.md"},
             {:root, ".github/copilot-instructions.md"},
             {:root, ".cursorrules"},
             {:root, ".cursor/rules/style.mdc"},
             {:nested, "lib/AGENTS.md"},
             {:nested, "lib/CLAUDE.md"},
             {:nested, "lib/.cursor/rules/lib.mdc"}
           ]

    {[agents], retired} =
      loaded.files
      |> Enum.reject(&(&1.scope == :brief))
      |> Enum.split_with(&(Path.basename(&1.path) == "AGENTS.md"))

    assert %{scope: :nested, status: :whole, text: "nested agents", skipped: []} = agents

    for file <- retired do
      assert %{status: :skipped, reason: ^onboard, size: 0, chars: 0, hash: nil, text: ""} = file
      assert %{rule: nil, applies: nil} = file
    end

    assert loaded.used == String.length("nested agents")

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "nested agents"

    for text <- ["claude's", "gemini's", "copilot's", "legacy", "cursor's", "nested claude"],
        do: refute(prompt =~ text)

    refute prompt =~ "nested cursor"

    assert [%{"status" => "skipped", "reason" => ^onboard, "size" => 0, "hash" => nil} | _] =
             Instructions.provenance(loaded)["files"]
  end

  # Decision 806: Copilot reads `.github/copilot-instructions.md` at the repository root
  # and nowhere else, so a nested one was never read, and still says why; the root's is no
  # longer read either (Decision 828).
  test "Copilot's file is read nowhere: at the root it waits for troupe onboard, nested it " <>
         "never counted",
       %{repo: repo} do
    write!(repo, ".github/copilot-instructions.md", "copilot's at the root")
    write!(repo, "lib/.github/copilot-instructions.md", "copilot's nested")
    write!(repo, "lib/x/AGENTS.md", "agents' nested")
    write!(repo, "lib/x/.github/copilot-instructions.md", "copilot's beside it")

    loaded = Instructions.load(Path.join(repo, "lib/x"), config())
    reason = "not read: Copilot's file counts only at the root"

    assert [
             %{
               scope: :root,
               status: :skipped,
               chars: 0,
               text: "",
               reason: "not read: run troupe onboard"
             },
             %{
               scope: :nested,
               where: "lib",
               status: :skipped,
               size: 0,
               chars: 0,
               hash: nil,
               text: "",
               reason: ^reason
             },
             %{
               scope: :nested,
               where: "lib/x",
               status: :whole,
               text: "agents' nested",
               skipped: []
             },
             %{scope: :nested, where: "lib/x", status: :skipped, chars: 0, reason: ^reason},
             %{scope: :brief}
           ] = loaded.files

    assert files(loaded, repo) == [
             {:root, ".github/copilot-instructions.md"},
             {:nested, "lib/.github/copilot-instructions.md"},
             {:nested, "lib/x/AGENTS.md"},
             {:nested, "lib/x/.github/copilot-instructions.md"}
           ]

    assert loaded.used == String.length("agents' nested")

    prompt = Instructions.to_prompt(loaded)
    refute prompt =~ "copilot's"

    assert [
             %{"status" => "skipped", "reason" => "not read: run troupe onboard"},
             %{"status" => "skipped", "reason" => ^reason, "chars" => 0, "hash" => nil},
             %{"status" => "whole", "reason" => nil},
             %{"status" => "skipped", "reason" => ^reason},
             %{"scope" => "brief", "reason" => nil}
           ] = Instructions.provenance(loaded)["files"]
  end

  # Decision 828: Copilot's `.github/instructions/*.instructions.md` were never read, and
  # onboarding brings them in (Decision 827), so they are listed as waiting for it, as
  # every other tool's file is; at the root only, where Copilot reads them.
  test "Copilot's .github/instructions files at the root are listed as skipped, never read",
       %{base: base, repo: repo} do
    write!(
      repo,
      ".github/instructions/ts.instructions.md",
      "---\napplyTo: \"**\"\n---\ncopilot's rule"
    )

    write!(repo, ".github/instructions/notes.md", "not one of Copilot's")
    write!(repo, "lib/.github/instructions/lib.instructions.md", "nested, never read")
    write!(base, "elsewhere/x.instructions.md", "outside")

    loaded = Instructions.load(repo, config(), ["lib/a.ex"])

    assert files(loaded, repo) == [{:root, ".github/instructions/ts.instructions.md"}]

    assert [
             %{
               status: :skipped,
               reason: "not read: run troupe onboard",
               size: 0,
               chars: 0,
               hash: nil,
               text: "",
               rule: nil
             },
             %{scope: :brief}
           ] = loaded.files

    refute Instructions.to_prompt(loaded) =~ "copilot's rule"

    # A `.github/instructions` that is a link out is listed once, its files not named.
    File.rm_rf!(Path.join(repo, ".github/instructions"))
    :ok = File.ln_s(Path.join(base, "elsewhere"), Path.join(repo, ".github/instructions"))

    assert [%{status: :outside, path: path}, %{scope: :brief}] =
             Instructions.load(repo, config()).files

    assert path == Path.join(repo, ".github/instructions")
  end

  # D84 and D99: a file that is there and cannot be read is listed with why, not only
  # logged, so `context.get` shows it was left out.
  test "an AGENTS.md or an .agents/AGENTS.md that cannot be read is listed, saying why", %{
    repo: repo
  } do
    write!(repo, ".agents/AGENTS.md", "the root's .agents, unreadable")
    write!(repo, "AGENTS.md", "the root's own, unreadable")
    write!(repo, "web/AGENTS.md", "web's own")
    File.chmod!(Path.join(repo, ".agents/AGENTS.md"), 0o000)
    File.chmod!(Path.join(repo, "AGENTS.md"), 0o000)

    loaded = Instructions.load(repo, config(), ["web/a.ts"])
    denied = "not read: permission denied"

    assert [
             %{scope: :root, status: :unreadable, chars: 0, size: 0, hash: nil, reason: ^denied},
             %{scope: :root, status: :unreadable, chars: 0, text: "", reason: ^denied},
             %{scope: :nested, status: :whole, text: "web's own"},
             %{scope: :brief}
           ] = loaded.files

    assert files(loaded, repo) == [
             {:root, ".agents/AGENTS.md"},
             {:root, "AGENTS.md"},
             {:nested, "web/AGENTS.md"}
           ]

    assert loaded.used == String.length("web's own")
    refute Instructions.to_prompt(loaded) =~ "unreadable"

    assert [%{"status" => "unreadable", "reason" => ^denied, "chars" => 0} | _] =
             Instructions.provenance(loaded)["files"]
  end

  test "the budget keeps the nearest whole first and says what it cut", %{repo: repo} do
    write!(repo, "AGENTS.md", String.duplicate("r", 100))
    write!(repo, "a/AGENTS.md", String.duplicate("m", 100))
    write!(repo, "a/b/AGENTS.md", String.duplicate("n", 100))

    loaded = Instructions.load(Path.join(repo, "a/b"), config(instructions_max_chars: 150))

    assert [
             %{
               scope: :root,
               status: :dropped,
               chars: 0,
               trimmed: 100,
               text: "",
               reason: "left out: the budget was spent on nearer files"
             },
             %{scope: :nested, status: :trimmed, chars: 50, trimmed: 50, text: text, reason: nil},
             %{scope: :nested, status: :whole, chars: 100, trimmed: 0},
             %{scope: :brief}
           ] = loaded.files

    assert text == String.duplicate("m", 50)
    assert loaded.budget == 150
    assert loaded.used == 150

    prompt = Instructions.to_prompt(loaded)

    assert prompt =~
             "(repository root): left out, the instructions budget of 150 characters was spent on nearer files."

    assert prompt =~ String.duplicate("m", 50) <> "\n\n(cut here: 50 more characters"
    assert prompt =~ String.duplicate("n", 100)

    provenance = Instructions.provenance(loaded)
    assert provenance["budget"] == 150
    assert provenance["used"] == 150

    assert Enum.map(provenance["files"], &{&1["status"], &1["chars"], &1["trimmed"], &1["share"]}) ==
             [
               {"dropped", 0, 100, 0.0},
               {"trimmed", 50, 50, 0.333},
               {"whole", 100, 0, 0.667},
               {"absent", 0, 0, 0.0}
             ]
  end

  # Decision 798: where the session works is its workspace and the directory of every file
  # its conversation read, edited or wrote.
  test "a file the conversation worked on brings the file of each directory on its way", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "root rule")
    write!(repo, "frontend/AGENTS.md", "frontend rule")
    write!(repo, "frontend/app/AGENTS.md", "app rule")
    write!(repo, "backend/AGENTS.md", "backend rule")
    write!(repo, "docs/AGENTS.md", "not worked in")

    focus = [
      "frontend/app/main.ts",
      Path.join(repo, "backend/lib/server.ex"),
      "../elsewhere/AGENTS.md"
    ]

    loaded = Instructions.load(repo, config(), focus)

    assert files(loaded, repo) == [
             {:root, "AGENTS.md"},
             {:nested, "backend/AGENTS.md"},
             {:nested, "frontend/AGENTS.md"},
             {:nested, "frontend/app/AGENTS.md"}
           ]

    assert Path.join(repo, "backend/lib") in loaded.searched
    refute Path.expand(Path.join(repo, "../elsewhere")) in loaded.searched

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "(nearer: frontend/app/):\napp rule"
    refute prompt =~ "not worked in"
    assert Instructions.load(repo, config()).digest != loaded.digest
  end

  test "the conversation's focus is the files it read, edited or wrote" do
    conversation = [
      Message.user("go"),
      Message.assistant([
        %ToolUse{id: "1", name: "read_file", input: %{"path" => "a/x.ex"}},
        %ToolUse{id: "2", name: "grep", input: %{"pattern" => "x", "path" => "b"}}
      ]),
      Message.tool_results([
        %ToolResult{tool_use_id: "1", content: "x"},
        %ToolResult{tool_use_id: "2", content: "y"}
      ]),
      Message.assistant([
        %ToolUse{id: "3", name: "edit_file", input: %{"path" => "c/y.ex"}},
        %ToolUse{id: "4", name: "write_file", input: %{"path" => "a/x.ex"}}
      ])
    ]

    assert Instructions.focus(conversation) == ["a/x.ex", "c/y.ex"]
    assert Instructions.focus([]) == []
  end

  test "an @import is read right after the file that names it, from its directory, once", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", """
    # Rules
    See @docs/style.md, then @docs/style.md again, and @.github/review.md.
    Mail someone@example.com or ask @alice.
    `@docs/quoted.md` is code, and so is this:
    ```
    @docs/fenced.md
    ```
    """)

    write!(repo, "docs/style.md", "Style: tabs. See @../docs/terms.md")
    write!(repo, "docs/terms.md", "Terms.")
    write!(repo, ".github/review.md", "Review.")
    write!(repo, "docs/quoted.md", "never read")
    write!(repo, "docs/fenced.md", "never read")

    loaded = Instructions.load(repo, config())
    root = Path.join(repo, "AGENTS.md")
    style = Path.join(repo, "docs/style.md")

    assert [
             %{scope: :root, path: ^root, imported_by: nil, unfollowed: []},
             %{
               scope: :root,
               path: ^style,
               imported_by: ^root,
               text: "Style: tabs. See @../docs/terms.md"
             },
             %{scope: :root, text: "Terms.", imported_by: ^style},
             %{scope: :root, text: "Review.", imported_by: ^root},
             %{scope: :brief}
           ] = loaded.files

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "Contents of #{style} (repository root, imported by #{root}):\nStyle: tabs."
    refute prompt =~ "never read"

    assert [_root, %{"imported_by" => ^root, "scope" => "root", "size" => 34} | _] =
             Instructions.provenance(loaded)["files"]
  end

  test "imports stop five deep, at a cycle and at the repository's edge, and say so", %{
    base: base,
    repo: repo
  } do
    write!(repo, "AGENTS.md", "@one.md @gone/missing.md @../outside.md @~/secret.md")
    write!(repo, "one.md", "@two.md")
    write!(repo, "two.md", "@three.md")
    write!(repo, "three.md", "@four.md")
    write!(repo, "four.md", "@five.md")
    write!(repo, "five.md", "@six.md @one.md")
    write!(repo, "six.md", "too deep")
    write!(base, "outside.md", "the world outside")

    loaded = Instructions.load(repo, config())
    [agents | imported] = Enum.reject(loaded.files, &(&1.scope == :brief))

    assert agents.unfollowed == [
             %{import: "gone/missing.md", reason: :missing},
             %{import: "../outside.md", reason: :outside},
             %{import: "~/secret.md", reason: :outside}
           ]

    assert Enum.map(imported, &Path.basename(&1.path)) ==
             ["one.md", "two.md", "three.md", "four.md", "five.md"]

    assert List.last(imported).unfollowed == [
             %{import: "six.md", reason: :depth},
             %{import: "one.md", reason: :cycle}
           ]

    prompt = Instructions.to_prompt(loaded)
    refute prompt =~ "too deep"
    refute prompt =~ "the world outside"

    assert %{"unfollowed" => [%{"import" => "gone/missing.md", "reason" => "missing"} | _]} =
             hd(Instructions.provenance(loaded)["files"])
  end

  test "an instruction file or a brief that is a link to outside the repository is not read, " <>
         "and says so",
       %{base: base, repo: repo} do
    write!(base, "key", "a stand-in for a private key")
    File.ln_s!(Path.join(base, "key"), Path.join(repo, "AGENTS.md"))
    write!(repo, "CLAUDE.md", "another tool's file, never read")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.ln_s!(Path.join(base, "key"), Path.join(repo, "lib/AGENTS.md"))
    write!(repo, "docs/rules.md", "linked from inside")
    File.mkdir_p!(Path.join(repo, "web"))
    File.ln_s!(Path.join(repo, "docs/rules.md"), Path.join(repo, "web/AGENTS.md"))
    write!(base, "brief.md", "## Overview\na stand-in for a private key in a brief\n")
    File.mkdir_p!(Path.join(repo, ".troupe"))
    File.ln_s!(Path.join(base, "brief.md"), Path.join(repo, ".troupe/memory.md"))

    loaded = Instructions.load(repo, config(), ["lib/a.ex", "web/b.ts"])

    outside = "not read: outside the repository"

    assert [
             %{
               scope: :root,
               status: :outside,
               size: 0,
               chars: 0,
               hash: nil,
               skipped: [],
               reason: ^outside
             },
             %{scope: :root, status: :skipped, chars: 0, reason: "not read: run troupe onboard"},
             %{scope: :nested, where: "lib", status: :outside, chars: 0, reason: ^outside},
             %{scope: :nested, where: "web", status: :whole, text: "linked from inside"},
             %{
               scope: :brief,
               status: :outside,
               size: 0,
               chars: 0,
               hash: nil,
               text: "",
               reason: ^outside
             }
           ] = loaded.files

    assert loaded.used == String.length("linked from inside")

    prompt = Instructions.to_prompt(loaded)
    refute prompt =~ "private key"
    refute prompt =~ "never read"
    refute prompt =~ "Contents of #{Path.join(repo, "AGENTS.md")}"

    assert [%{"status" => "outside", "size" => 0, "hash" => nil, "reason" => ^outside} | _] =
             Instructions.provenance(loaded)["files"]
  end

  test "a file and its imports are one scope: the nearer scope is kept whole first", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "@a.md " <> String.duplicate("r", 94))
    write!(repo, "a.md", String.duplicate("a", 100))
    write!(repo, "x/AGENTS.md", String.duplicate("n", 100))

    loaded = Instructions.load(repo, config(instructions_max_chars: 150), ["x/f.ex"])
    root = Path.join(repo, "AGENTS.md")

    assert [
             %{scope: :root, status: :trimmed, chars: 50, trimmed: 50},
             %{scope: :root, status: :dropped, chars: 0, trimmed: 100, imported_by: ^root},
             %{scope: :nested, status: :whole, chars: 100},
             %{scope: :brief}
           ] = loaded.files
  end

  # Decisions 809 and 828: `.troupe/rules/*.md` as Cursor reads its rules, after the
  # directory's own instruction file, in name order.
  test "rules: an always rule joins, a glob rule waits for a file it matches, a " <>
         "description-only rule is listed, one with neither is not joined",
       %{repo: repo} do
    write!(repo, "AGENTS.md", "root rule")

    write!(repo, ".troupe/rules/always.md", """
    ---
    description: House style
    globs: lib/**
    alwaysApply: true
    ---
    Use tabs.
    """)

    write!(repo, ".troupe/rules/ts.md", """
    ---
    description:
    globs: src/**/*.ts, *.tsx
    alwaysApply: false
    ---
    TypeScript: strict.
    """)

    write!(repo, ".troupe/rules/db.md", """
    ---
    description: "Writing a
      database migration"
    globs:
    alwaysApply: false
    ---
    Migrations: reversible.
    """)

    write!(repo, ".troupe/rules/manual.md", "---\nalwaysApply: false\n---\nOnly when named.")
    write!(repo, ".troupe/rules/bare.md", "No front matter at all.")
    write!(repo, ".troupe/rules/notes.txt", "not a rule")
    write!(repo, ".troupe/rules/old.mdc", "---\nalwaysApply: true\n---\nnot a rule either")

    loaded = Instructions.load(repo, config(), ["lib/a.ex"])

    assert files(loaded, repo) == [
             {:root, "AGENTS.md"},
             {:root, ".troupe/rules/always.md"},
             {:root, ".troupe/rules/bare.md"},
             {:root, ".troupe/rules/db.md"},
             {:root, ".troupe/rules/manual.md"},
             {:root, ".troupe/rules/ts.md"}
           ]

    manual = "not joined: no alwaysApply, globs or description"
    waiting = "applies when a file matching src/**/*.ts or *.tsx is read or edited"

    assert [
             %{rule: nil, applies: nil},
             %{status: :whole, text: "Use tabs.", applies: "always applied", reason: nil},
             %{status: :inactive, chars: 0, text: "", reason: ^manual, rule: %{apply: :manual}},
             %{
               status: :listed,
               text: "Writing a database migration",
               chars: 28,
               reason: "requested by description only: listed in the prompt, not joined",
               rule: %{apply: :requested, globs: [], description: "Writing a database migration"}
             },
             %{status: :inactive, reason: ^manual},
             %{
               status: :inactive,
               chars: 0,
               size: size,
               hash: "sha256:" <> _,
               reason: ^waiting,
               applies: nil,
               rule: %{apply: :globs, globs: ["src/**/*.ts", "*.tsx"], matched: nil}
             },
             %{scope: :brief}
           ] = loaded.files

    assert size > 0

    assert loaded.used ==
             String.length("root rule") + String.length("Use tabs.") +
               String.length("Writing a database migration")

    prompt = Instructions.to_prompt(loaded)
    always = Path.join(repo, ".troupe/rules/always.md")
    db = Path.join(repo, ".troupe/rules/db.md")

    assert prompt =~
             "Contents of #{always} (repository root, a rule that always applies):\nUse tabs."

    assert prompt =~ "Rule #{db} (repository root), to read when it applies: Writing a database"
    refute prompt =~ "alwaysApply"
    refute prompt =~ "strict"
    refute prompt =~ "reversible"
    refute prompt =~ "Only when named"
    refute prompt =~ "front matter at all"
    refute prompt =~ "not a rule"

    # The order of the prompt is the order of the files: the rules after the root's own.
    assert [_head, "root rule", "Use tabs." <> _] =
             prompt |> String.split(~r/Contents of [^\n]+\n/) |> Enum.map(&String.trim/1)

    # A file worked on that a glob matches joins the rule, from the turn that reads it.
    for {focus, matched, glob} <- [
          {"src/app/main.ts", "src/app/main.ts", "src/**/*.ts"},
          {Path.join(repo, "web/App.tsx"), "web/App.tsx", "*.tsx"}
        ] do
      joined = Instructions.load(repo, config(), ["lib/a.ex", focus])
      ts = Enum.find(joined.files, &String.ends_with?(&1.path, "ts.md"))

      assert %{
               status: :whole,
               reason: nil,
               text: "TypeScript: strict.",
               applies: applies,
               rule: %{matched: ^matched}
             } = ts

      assert applies == "applied: #{matched} matches #{glob}"
      assert joined.digest != loaded.digest

      assert Instructions.to_prompt(joined) =~
               "(repository root, a rule for files matching src/**/*.ts or *.tsx):\n" <>
                 "TypeScript: strict."
    end

    assert [
             %{"rule" => nil, "applies" => nil},
             %{"rule" => %{"apply" => "always"}, "applies" => "always applied"},
             _bare,
             %{"status" => "listed", "chars" => 28, "rule" => %{"apply" => "requested"}},
             _manual,
             %{
               "status" => "inactive",
               "reason" => ^waiting,
               "applies" => nil,
               "rule" => %{
                 "apply" => "globs",
                 "globs" => ["src/**/*.ts", "*.tsx"],
                 "description" => nil,
                 "matched" => nil
               }
             },
             %{"scope" => "brief", "rule" => nil}
           ] = Instructions.provenance(loaded)["files"]
  end

  test "a rule's globs: a list in brackets or of lines, braces, a name anywhere, a path " <>
         "from the root, a directory",
       %{repo: repo} do
    write!(repo, ".troupe/rules/flow.md", "---\nglobs: [\"docs/*.md\", 'Makefile']\n---\nflow")

    write!(
      repo,
      ".troupe/rules/block.md",
      "---\nglobs:\n  - \"lib/**\"\n- test/*.exs\n---\nblock"
    )

    write!(repo, ".troupe/rules/brace.md", "---\nglobs: **/*.{ts,tsx}, a?.c\n---\nbrace")
    write!(repo, ".troupe/rules/dir.md", "---\nglobs: ./priv/\n---\ndir")

    globs = fn loaded ->
      for %{rule: %{globs: globs}, status: status} = f <- loaded.files,
          do: {Path.basename(f.path), globs, status}
    end

    assert globs.(Instructions.load(repo, config())) == [
             {"block.md", ["lib/**", "test/*.exs"], :inactive},
             {"brace.md", ["**/*.{ts,tsx}", "a?.c"], :inactive},
             {"dir.md", ["./priv/"], :inactive},
             {"flow.md", ["docs/*.md", "Makefile"], :inactive}
           ]

    joined = fn focus ->
      for %{status: :whole, rule: %{}} = f <- Instructions.load(repo, config(), focus).files,
          do: Path.basename(f.path)
    end

    assert joined.(["docs/guide.md"]) == ["flow.md"]
    assert joined.(["docs/deep/guide.md"]) == []
    assert joined.(["tools/Makefile"]) == ["flow.md"]
    assert joined.(["lib/a/b.ex", "test/x_test.exs"]) == ["block.md"]
    assert joined.(["test/deep/x_test.exs"]) == []
    assert joined.(["x.tsx"]) == ["brace.md"]
    assert joined.(["deep/x.ts"]) == ["brace.md"]
    assert joined.(["src/ab.c"]) == ["brace.md"]
    assert joined.(["src/abc.c"]) == []
    assert joined.(["priv/repo/seeds.exs"]) == ["dir.md"]
    assert joined.(["../priv/x", "lib.ex"]) == []
  end

  test "a nested .troupe/rules applies once the session works under its directory, its " <>
         "globs from there",
       %{repo: repo} do
    write!(repo, "web/.troupe/rules/web.md", "---\nalwaysApply: true\n---\nWeb: use pnpm.")
    write!(repo, "web/.troupe/rules/ts.md", "---\nglobs: src/**\n---\nWeb TypeScript.")
    write!(repo, "api/.troupe/rules/api.md", "---\nalwaysApply: true\n---\nnot worked in")
    write!(repo, ".troupe/rules.d/x.md", "not a rules directory")

    assert files(Instructions.load(repo, config()), repo) == []

    loaded = Instructions.load(repo, config(), ["web/index.html"])

    assert [
             %{
               scope: :nested,
               where: "web",
               status: :inactive,
               reason: "applies when a file under web/ matching src/** is read or edited"
             },
             %{scope: :nested, where: "web", status: :whole, text: "Web: use pnpm."},
             %{scope: :brief}
           ] = loaded.files

    assert Instructions.to_prompt(loaded) =~ "(nearer: web/, a rule that always applies):\nWeb"

    loaded = Instructions.load(repo, config(), ["web/src/main.ts", "src/root.ts"])

    assert [
             %{status: :whole, applies: "applied: web/src/main.ts matches src/** under web/"},
             %{text: "Web: use pnpm."},
             %{scope: :brief}
           ] = loaded.files

    refute Instructions.to_prompt(loaded) =~ "not worked in"
  end

  test "a rule, a .troupe/rules or a .troupe that is a link to outside the repository is not " <>
         "read, nor the names of what is there",
       %{base: base, repo: repo} do
    write!(base, "key", "---\nalwaysApply: true\n---\na stand-in for a private key")
    write!(base, "elsewhere/secret.md", "---\nalwaysApply: true\n---\nanother stand-in")
    write!(base, "dot-troupe/rules/hidden.md", "---\nalwaysApply: true\n---\na third stand-in")
    File.mkdir_p!(Path.join(repo, ".troupe/rules"))
    File.ln_s!(Path.join(base, "key"), Path.join(repo, ".troupe/rules/linked.md"))
    write!(repo, "docs/inside.md", "---\nalwaysApply: true\n---\nlinked from inside")
    File.ln_s!(Path.join(repo, "docs/inside.md"), Path.join(repo, ".troupe/rules/inside.md"))
    File.mkdir_p!(Path.join(repo, "lib/.troupe"))
    File.ln_s!(Path.join(base, "elsewhere"), Path.join(repo, "lib/.troupe/rules"))
    File.mkdir_p!(Path.join(repo, "web"))
    File.ln_s!(Path.join(base, "dot-troupe"), Path.join(repo, "web/.troupe"))

    loaded = Instructions.load(repo, config(), ["lib/a.ex", "web/b.ts"])
    outside = "not read: outside the repository"
    linked = Path.join(repo, ".troupe/rules/linked.md")
    rules = Path.join(repo, "lib/.troupe/rules")
    web = Path.join(repo, "web/.troupe/rules")

    assert [
             %{status: :whole, text: "linked from inside"},
             %{path: ^linked, status: :outside, size: 0, hash: nil, rule: nil, reason: ^outside},
             %{path: ^rules, scope: :nested, status: :outside, chars: 0, reason: ^outside},
             %{path: ^web, scope: :nested, status: :outside, chars: 0, reason: ^outside},
             %{scope: :brief}
           ] = loaded.files

    prompt = Instructions.to_prompt(loaded)
    refute prompt =~ "stand-in"
    refute inspect(Instructions.provenance(loaded)) =~ "secret.md"
    refute inspect(Instructions.provenance(loaded)) =~ "hidden.md"
  end

  test "a rule counts against the budget as a file does, and a listed one is whole or out", %{
    repo: repo
  } do
    write!(
      repo,
      ".troupe/rules/a.md",
      "---\nalwaysApply: true\n---\n" <> String.duplicate("a", 30)
    )

    write!(
      repo,
      ".troupe/rules/b.md",
      "---\ndescription: #{String.duplicate("b", 30)}\n---\nbody"
    )

    write!(repo, "x/AGENTS.md", String.duplicate("n", 20))

    loaded = Instructions.load(repo, config(instructions_max_chars: 45), ["x/f.ex"])

    assert [
             %{status: :trimmed, chars: 25, trimmed: 5},
             %{
               status: :dropped,
               chars: 0,
               trimmed: 30,
               text: "",
               reason: "left out: the budget was spent on nearer files"
             },
             %{scope: :nested, status: :whole, chars: 20},
             %{scope: :brief}
           ] = loaded.files

    assert loaded.used == 45
  end

  test "without a .git the workspace is the root; a .git file, a worktree's, is one too", %{
    base: base
  } do
    plain = Path.join(base, "plain")
    write!(plain, "AGENTS.md", "plain")
    write!(plain, "sub/AGENTS.md", "sub")
    loaded = Instructions.load(Path.join(plain, "sub"), config())
    assert files(loaded, Path.expand(plain)) == [{:root, "sub/AGENTS.md"}]
    assert Path.expand(Path.join(plain, "sub")) in loaded.searched

    worktree = Path.join(base, "worktree")
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: elsewhere\n")
    write!(worktree, "AGENTS.md", "the branch's own")
    loaded = Instructions.load(Path.join(worktree, "deep"), config())
    assert files(loaded, Path.expand(worktree)) == [{:root, "AGENTS.md"}]
  end

  test "the digest follows the content, and the brief is listed with its own budget", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "one")
    first = Instructions.load(repo, config())
    assert Instructions.load(repo, config()).digest == first.digest

    write!(repo, "AGENTS.md", "two")
    assert Instructions.load(repo, config()).digest != first.digest

    # A brief's command that does not fit the cap: left out, counted, and named for
    # `recall` (Decision 838). The size is the view's, as a person opens it.
    write!(repo, ".troupe/memory.md", "## Commands\n- A brief.\n")
    with_brief = Instructions.load(repo, config(memory_max_chars: 3))
    assert with_brief.digest != first.digest

    assert %{
             scope: :brief,
             status: :trimmed,
             budget: 3,
             size: size,
             hash: "sha256:" <> _,
             trimmed: trimmed
           } =
             List.last(with_brief.files)

    assert size == File.stat!(Path.join(repo, ".troupe/memory.md")).size
    assert trimmed == String.length("- A brief.")

    assert Instructions.to_prompt(with_brief) =~
             "# Project brief\n1 fact about this repository (1 command)"

    refute Instructions.to_prompt(with_brief, recall: false) =~ "# Project brief"

    off = Instructions.load(repo, config(memory: false))
    assert %{scope: :brief, status: :disabled, chars: 0, text: ""} = List.last(off.files)
    refute Instructions.to_prompt(off) =~ "# Project brief"
  end

  test "an empty workspace has nothing but the brief's line, and no prompt block", %{repo: repo} do
    loaded = Instructions.load(repo, config())
    assert [%{scope: :brief, status: :absent, chars: 0}] = loaded.files
    assert loaded.used == 0
    assert Instructions.to_prompt(loaded) == ""
  end

  # The brief lives in the repository's main checkout, which is a question for `git`, and
  # this read comes before every model call: the path is asked for once, not once for the
  # path, once for the text and once for what the budget cut.
  test "reading the brief asks git where the repository is once", %{repo: repo} do
    write!(repo, ".troupe/memory.md", "## Overview\nA brief.\n")

    {loaded, gits} = gits(fn -> Instructions.load(repo, config()) end)
    assert %{files: [%{scope: :brief, status: :whole}]} = loaded
    assert gits == 1
  end

  # How many times `fun` ran `git` in this process: every one goes through the reaper, and a
  # tracer beside the test counts the calls (a process is not its own tracer).
  defp gits(fun) do
    Code.ensure_loaded!(Troupe.Reaper)
    assert :erlang.trace_pattern({Troupe.Reaper, :run, 3}, true, [:local]) == 1
    on_exit(fn -> :erlang.trace_pattern({Troupe.Reaper, :run, 3}, false, [:local]) end)
    tracer = spawn_link(fn -> count_gits(0) end)

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    result = fun.()
    :erlang.trace(self(), false, [:call])

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, {:count, self()})
    assert_receive {:gits, count}
    {result, count}
  end

  defp count_gits(count) do
    receive do
      {:trace, _pid, :call, {Troupe.Reaper, :run, [_cwd, ["git" | _args], _opts]}} ->
        count_gits(count + 1)

      {:trace, _pid, :call, _other} ->
        count_gits(count)

      {:count, from} ->
        send(from, {:gits, count})
    end
  end

  defp write!(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp config(overrides \\ []), do: struct!(Troupe.Config, overrides)

  defp files(loaded, root) do
    for f <- loaded.files, f.scope != :brief, do: {f.scope, Path.relative_to(f.path, root)}
  end
end
