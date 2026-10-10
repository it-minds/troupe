defmodule Troupe.InstructionsPromptTest do
  @moduledoc """
  The instruction files in a real session's prompt (Decisions 706, 798, 806, 809 and 828):
  a repository with only an `AGENTS.md` needs no Troupe-specific setup, and one with only
  another tool's file reaches no prompt, the event saying to run `troupe onboard`; an edit
  reaches the next turn and not the next call, a nested file on the way to what a turn
  worked on is in the next turn's prompt (a nested Copilot file is not, and the event says
  why), an import reaches it, the `instructions_loaded` event is written when what was
  read changed and not otherwise and says what the budget cut, the person's own
  `<config>/AGENTS.md` comes first, the brief last, nothing reaches the prompt from a file
  without appearing in the provenance, and `.troupe/rules` join it when their front
  matter says.

  `async: false`: one test writes the suite's shared config home.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.{Instructions, Paths}

  @haiku "# Rules\n\nAlways answer in haiku.\n"
  @limerick "# Rules\n\nAlways answer in limericks.\n"

  test "a repository with only an AGENTS.md is read into the prompt, and an edit reaches the next turn",
       context do
    write_file(context, "AGENTS.md", @haiku)

    %{session: session, fake: fake} =
      start_session(context, steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}])

    :ok = Troupe.subscribe(session.id)
    path = Path.join(Path.expand(context.workspace), "AGENTS.md")

    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)
    [first] = Fake.requests(fake)
    assert first.system =~ "# Instruction files"

    assert first.system =~
             "Contents of #{path} (repository root):\n# Rules\n\nAlways answer in haiku."

    # The file is read again at the next turn, not distilled once.
    write_file(context, "AGENTS.md", @limerick)
    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)
    [_first, second] = Fake.requests(fake)
    assert second.system =~ "Always answer in limericks."
    refute second.system =~ "haiku"

    # A turn that read the same files again writes no event: the digest is the cache.
    Troupe.send_input(session.id, "once more")
    await_event(session.id, :turn_ended)
    assert length(Fake.requests(fake)) == 3

    assert [before, after_edit] = events_of_type(session.id, :instructions_loaded)
    assert before.agent == ["root"]
    assert before.data["budget"] == 16_000
    assert before.data["used"] == String.length(String.trim(@haiku))

    assert [
             %{"scope" => "root", "path" => ^path, "status" => "whole", "skipped" => []} = root,
             %{"scope" => "brief", "status" => "absent", "chars" => 0}
           ] = before.data["files"]

    assert root["size"] == byte_size(@haiku)
    assert root["chars"] == String.length(String.trim(@haiku))
    assert root["share"] == Float.round(root["chars"] / 16_000, 3)
    assert root["hash"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, @haiku), case: :lower)
    assert after_edit.data["files"] |> hd() |> Map.get("hash") != root["hash"]
  end

  # Decision 828: other tools' files are brought in once by `troupe onboard`, and a session
  # reads none of them; the event names each, saying so.
  test "a repository with only a CLAUDE.md, a GEMINI.md, a copilot file or Cursor's rules " <>
         "reaches no prompt, and the event says to run troupe onboard",
       context do
    for name <- [
          "CLAUDE.md",
          "GEMINI.md",
          ".github/copilot-instructions.md",
          ".cursorrules",
          ".cursor/rules/style.mdc"
        ] do
      repo = %{context | workspace: Path.join(context.base, "repo-" <> Path.basename(name))}
      write_file(repo, name, "---\nalwaysApply: true\n---\n" <> @haiku)

      %{session: session, fake: fake} = start_session(repo, steps: [{:text, "one"}])
      :ok = Troupe.subscribe(session.id)
      path = Path.join(Path.expand(repo.workspace), name)

      Troupe.send_input(session.id, "hello")
      await_event(session.id, :turn_ended)
      [first] = Fake.requests(fake)
      refute first.system =~ "haiku"
      refute first.system =~ "# Instruction files"

      assert [event] = events_of_type(session.id, :instructions_loaded)

      assert [
               %{
                 "scope" => "root",
                 "path" => ^path,
                 "status" => "skipped",
                 "chars" => 0,
                 "reason" => "not read: run troupe onboard"
               },
               %{"scope" => "brief"}
             ] = event.data["files"]

      Troupe.stop_session(session.id)
    end
  end

  # Decision 798: a turn reads the files once, as it begins, so the system prompt is the
  # same on every call of a turn, and the next turn reads the directories the conversation
  # worked in as well as the workspace.
  test "a nested AGENTS.md on the way to a file the turn read is in the next turn's prompt, " <>
         "and the prompt holds still within a turn",
       context do
    write_file(context, "AGENTS.md", @haiku)
    write_file(context, "frontend/AGENTS.md", "Frontend: use pnpm.\n")
    write_file(context, "frontend/app/main.ts", "export {}\n")

    %{session: session, fake: fake} =
      start_session(context,
        steps: [
          {:tools, [{"read_file", %{"path" => "frontend/app/main.ts"}}]},
          {:tools, [{"write_file", %{"path" => "AGENTS.md", "content" => @limerick}}]},
          {:text, "one"},
          {:text, "two"}
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [a, b, c] = Fake.requests(fake)
    assert a.system == b.system
    assert b.system == c.system
    assert a.system =~ "haiku"
    refute a.system =~ "pnpm"

    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)
    [_a, _b, _c, d] = Fake.requests(fake)
    nested = Path.join(Path.expand(context.workspace), "frontend/AGENTS.md")
    assert d.system =~ "Always answer in limericks."
    refute d.system =~ "haiku"
    assert [_before, after_root] = String.split(d.system, "Always answer in limericks.")
    assert after_root =~ "Contents of #{nested} (nearer: frontend/):\nFrontend: use pnpm."

    assert [_first, second] = events_of_type(session.id, :instructions_loaded)

    assert [
             %{"scope" => "root"},
             %{"scope" => "nested", "path" => ^nested},
             %{"scope" => "brief"}
           ] =
             second.data["files"]

    assert Path.join(Path.expand(context.workspace), "frontend/app") in second.data["searched"]
  end

  test "an @import reaches the prompt, and what the budget cut is in the event", context do
    write_file(context, "AGENTS.md", "Read @docs/style.md first.\n")
    write_file(context, "docs/style.md", String.duplicate("s", 50))

    %{session: session, fake: fake} =
      start_session(context,
        steps: [{:text, "ok"}],
        config_overrides: [instructions_max_chars: 40]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)
    root = Path.join(Path.expand(context.workspace), "AGENTS.md")
    style = Path.join(Path.expand(context.workspace), "docs/style.md")

    assert request.system =~
             "Contents of #{style} (repository root, imported by #{root}):\n" <>
               String.duplicate("s", 14) <> "\n\n(cut here: 36 more characters"

    assert [event] = events_of_type(session.id, :instructions_loaded)
    assert event.data["budget"] == 40
    assert event.data["used"] == 40

    assert [
             %{"path" => ^root, "status" => "whole", "chars" => 26},
             %{"path" => ^style, "imported_by" => ^root, "status" => "trimmed", "trimmed" => 36},
             %{"scope" => "brief"}
           ] = event.data["files"]
  end

  test "an instruction file or a brief that is a link to outside the repository, or outside " <>
         "your config directory, reaches no prompt and is named in the event",
       context do
    outside = Path.join(context.base, "key")
    File.write!(outside, "a stand-in for a private key\n")
    File.ln_s!(outside, Path.join(context.workspace, "AGENTS.md"))
    brief = Path.join(context.base, "brief.md")
    File.write!(brief, "## Overview\na stand-in for a private key in a brief\n")
    File.mkdir_p!(Path.join(context.workspace, ".troupe"))
    File.ln_s!(brief, Path.join(context.workspace, ".troupe/memory.md"))

    mine = Path.join(Paths.config_dir(), "AGENTS.md")
    File.ln_s!(outside, mine)
    on_exit(fn -> File.rm(mine) end)

    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)
    refute request.system =~ "private key"
    refute request.system =~ "# Instruction files"
    refute request.system =~ "# Project brief"

    assert [event] = events_of_type(session.id, :instructions_loaded)

    assert [
             %{
               "scope" => "user",
               "status" => "outside",
               "chars" => 0,
               "reason" => "not read: outside the config directory"
             },
             %{
               "scope" => "root",
               "status" => "outside",
               "chars" => 0,
               "hash" => nil,
               "reason" => "not read: outside the repository"
             },
             %{"scope" => "brief", "status" => "outside", "size" => 0, "hash" => nil}
           ] = event.data["files"]
  end

  # Decision 806: Copilot reads its file at the repository root only, so one below it does
  # not reach the prompt, and the event names it as skipped with why.
  test "a nested Copilot file on the way to a file the turn read is not in the next turn's " <>
         "prompt, and the event says why",
       context do
    write_file(context, "AGENTS.md", @haiku)
    write_file(context, "frontend/.github/copilot-instructions.md", "Frontend: use pnpm.\n")
    write_file(context, "frontend/app/main.ts", "export {}\n")

    %{session: session, fake: fake} =
      start_session(context,
        steps: [
          {:tools, [{"read_file", %{"path" => "frontend/app/main.ts"}}]},
          {:text, "one"},
          {:text, "two"}
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)
    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)

    [_a, _b, c] = Fake.requests(fake)
    assert c.system =~ "Always answer in haiku."
    refute c.system =~ "pnpm"

    nested = Path.join(Path.expand(context.workspace), "frontend/.github/copilot-instructions.md")
    assert [_first, second] = events_of_type(session.id, :instructions_loaded)

    assert [
             %{"scope" => "root", "status" => "whole"},
             %{
               "scope" => "nested",
               "path" => ^nested,
               "status" => "skipped",
               "chars" => 0,
               "reason" => "not read: Copilot's file counts only at the root"
             },
             %{"scope" => "brief"}
           ] = second.data["files"]
  end

  test "your own AGENTS.md may import from your config directory", context do
    mine = Path.join(Paths.config_dir(), "AGENTS.md")
    extra = Path.join(Paths.config_dir(), "mine/extra.md")
    File.mkdir_p!(Path.dirname(extra))
    File.write!(mine, "Mine. @mine/extra.md\n")
    File.write!(extra, "Extra of mine.\n")

    on_exit(fn ->
      File.rm(mine)
      File.rm_rf(Path.dirname(extra))
    end)

    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)

    assert request.system =~
             "(your own, every repository, imported by #{Path.expand(mine)}):\nExtra of mine."
  end

  test "your own AGENTS.md comes first, the repository's after it and the brief last", context do
    mine = Path.join(Paths.config_dir(), "AGENTS.md")
    File.write!(mine, "Mine: sign every commit.\n")
    on_exit(fn -> File.rm(mine) end)

    write_file(context, "AGENTS.md", "Theirs: run mix check.\n")
    write_file(context, ".troupe/memory.md", "## Overview\nA brief.\n")

    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)
    assert [_prompt, user, root] = String.split(request.system, "Contents of ")
    assert user =~ "(your own, every repository):\nMine: sign every commit."
    assert [_root, brief] = String.split(root, "(repository root):\nTheirs: run mix check.")
    assert brief =~ "# Project brief"
    assert brief =~ "A brief."

    assert Enum.map(events_of_type(session.id, :instructions_loaded), & &1.data["files"]) == [
             Instructions.provenance(context.workspace, Troupe.Config.load(context.workspace))[
               "files"
             ]
           ]
  end

  test "the prompt names exactly the files the provenance lists", context do
    write_file(context, "AGENTS.md", "root\n")
    write_file(context, "CLAUDE.md", "an alias nobody reads\n")

    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)

    in_prompt =
      ~r/^Contents of (.+) \(/m
      |> Regex.scan(request.system)
      |> Enum.map(fn [_line, path] -> path end)

    listed =
      context.workspace
      |> Instructions.provenance(Troupe.Config.load(context.workspace))
      |> Map.fetch!("files")
      |> Enum.filter(&(&1["chars"] > 0 and &1["scope"] != "brief"))
      |> Enum.map(& &1["path"])

    assert in_prompt == listed
    refute request.system =~ "an alias nobody reads"
  end

  # Decisions 809 and 828: `.troupe/rules/*.md` as Cursor read its rules. An `alwaysApply`
  # rule is in every prompt; a `globs` rule joins the turn after one that read a matching
  # file, and stays; a rule with only a description is listed by it, its body not joined.
  test "an always rule is in the first prompt, a glob rule joins the turn after a matching " <>
         "file is read and stays, a description-only rule is listed",
       context do
    write_file(context, ".troupe/rules/style.md", """
    ---
    description: House style
    alwaysApply: true
    ---
    Always answer in haiku.
    """)

    write_file(context, ".troupe/rules/ts.md", """
    ---
    globs: src/**/*.ts
    alwaysApply: false
    ---
    TypeScript: no any.
    """)

    write_file(context, ".troupe/rules/db.md", """
    ---
    description: Writing a database migration
    alwaysApply: false
    ---
    Migrations: always reversible.
    """)

    write_file(context, "src/app/main.ts", "export {}\n")

    %{session: session, fake: fake} =
      start_session(context,
        steps: [
          {:tools, [{"read_file", %{"path" => "src/app/main.ts"}}]},
          {:text, "one"},
          {:text, "two"},
          {:text, "three"}
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [a, b] = Fake.requests(fake)
    style = Path.join(Path.expand(context.workspace), ".troupe/rules/style.md")
    ts = Path.join(Path.expand(context.workspace), ".troupe/rules/ts.md")
    db = Path.join(Path.expand(context.workspace), ".troupe/rules/db.md")

    assert a.system =~
             "Contents of #{style} (repository root, a rule that always applies):\n" <>
               "Always answer in haiku."

    refute a.system =~ "alwaysApply"
    refute a.system =~ "no any"

    assert a.system =~
             "Rule #{db} (repository root), to read when it applies: " <>
               "Writing a database migration"

    refute a.system =~ "always reversible"
    assert b.system == a.system

    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)
    Troupe.send_input(session.id, "once more")
    await_event(session.id, :turn_ended)

    [_a, _b, c, d] = Fake.requests(fake)

    assert c.system =~
             "Contents of #{ts} (repository root, a rule for files matching src/**/*.ts):\n" <>
               "TypeScript: no any."

    assert d.system == c.system
    refute c.system =~ "always reversible"

    assert [first, second] = events_of_type(session.id, :instructions_loaded)

    assert [
             %{"path" => ^db, "status" => "listed", "reason" => db_reason},
             %{"path" => ^style, "status" => "whole", "applies" => "always applied"},
             %{
               "path" => ^ts,
               "status" => "inactive",
               "chars" => 0,
               "reason" => "applies when a file matching src/**/*.ts is read or edited"
             },
             %{"scope" => "brief"}
           ] = first.data["files"]

    assert db_reason =~ "requested by description only"

    assert [
             %{"path" => ^db, "status" => "listed"},
             %{"path" => ^style, "status" => "whole"},
             %{
               "path" => ^ts,
               "status" => "whole",
               "reason" => nil,
               "applies" => "applied: src/app/main.ts matches src/**/*.ts",
               "rule" => %{"apply" => "globs", "globs" => ["src/**/*.ts"]}
             },
             %{"scope" => "brief"}
           ] = second.data["files"]
  end
end
