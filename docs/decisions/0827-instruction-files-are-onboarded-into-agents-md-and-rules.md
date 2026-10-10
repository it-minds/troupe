---
number: 827
title: Other tools' instruction files are onboarded once, their substance into the AGENTS.md beside them and their rules into .troupe/rules/, a new AGENTS.md is its own question, a session's start proposes and never writes, and onboarding and the brief carry a version
date: 2026-10-10
status: accepted
issue: 516
paths:
  - apps/troupe_core/lib/troupe/onboard.ex
  - apps/troupe_core/lib/troupe/onboard/instructions.ex
  - apps/troupe_core/lib/troupe/onboard/notice.ex
  - apps/troupe_core/lib/troupe/onboard/source.ex
  - apps/troupe_core/lib/troupe/tools/onboard_write.ex
  - apps/troupe_core/lib/troupe/memory.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/priv/agents/librarian.md
  - apps/troupe_core/test/troupe/onboard/instructions_test.exs
  - apps/troupe_core/test/troupe/onboard/notice_test.exs
  - apps/troupe_core/test/troupe/onboard/librarian_test.exs
  - clients/tui/lib/troupe/cli/onboard.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/test/troupe/onboard_cli_test.exs
symbols:
  - Troupe.Onboard.Instructions
  - Troupe.Onboard.Notice.due/2
  - Troupe.Onboard.version/0
  - Troupe.Onboard.onboarded_version/2
  - Troupe.Onboard.stamp/1
  - Troupe.Memory.survey_version/0
gist: "CLAUDE.md etc. add only unsaid units to the AGENTS.md beside them; rules to .troupe/rules/; a new AGENTS.md asked alone; starts propose, never write"
---

Issue #516, slice 2, and the maintainer's decisions for this chunk's second wave: other
tools' instruction files stop being read at run time (Decision 828 removes the readers)
and are onboarded once instead; Cursor's rules are onboarded too, not read; onboarding
proposes by itself and never writes by itself; creating an `AGENTS.md` that does not
exist is asked as its own question; and what onboarding writes, and the librarian's
brief, record the version of the rules that wrote them. Before this, `troupe onboard` had
one source (agents and commands, Decision 824): a repository with only a `CLAUDE.md` got
no proposal at all, a session's start said nothing about onboarding, and the librarian's
prompt said `CLAUDE.md`, `GEMINI.md` and Copilot's file were already in every prompt.

- **A source for instruction files.** `Troupe.Onboard.Instructions` is registered first in
  `@sources`. `CLAUDE.md` and `GEMINI.md` (at the root and in any directory), and
  `.github/copilot-instructions.md` at the root only (Decision 806: Copilot reads it
  nowhere else, so a nested one is skipped), are other tools' names for a directory's
  `AGENTS.md`. They make one proposal per directory, for the `AGENTS.md` in that
  directory: the first file found, in the order `CLAUDE.md`, `GEMINI.md`, Copilot's, is
  `source` and the others `also_from`, so a change to any is drift and a new proposal.
  Rules make one proposal each: `.cursor/rules/*.mdc` (the root's and a directory's),
  the root's legacy `.cursorrules` (always applied), and Copilot's
  `.github/instructions/*.instructions.md` (the root's) become `.troupe/rules/<name>.md`.
  Found as `troupe instructions check` finds files: `.gitignore`, `node_modules`, a nested
  repository and hidden directories other than `.github` and `.cursor` are not entered,
  and the root's own files are looked for by name whatever `.gitignore` says, since their
  tools read them anyway. A file linked out of the workspace is not read; a `CLAUDE.md`
  that is the directory's `AGENTS.md` under another name gives nothing; each is listed as
  skipped with why, as is a nested Copilot file or `.cursorrules`, a rule in a folder under
  `.cursor/rules`, an empty file, and one whose every unit is said already.
- **Merge, don't duplicate, judged conservatively.** The `AGENTS.md` that is there is kept
  byte for byte (its Windows line endings too) and what each other file adds comes after
  it. A file is read as Markdown units: a paragraph, a list item, a fenced block, a table,
  a heading. A unit is *said already*, and left out, in exactly two cases: its text equals
  a unit of the directory's `AGENTS.md`, of its `.agents/AGENTS.md`, or of a file before
  it in the same proposal, spaces aside; or it is, in `troupe instructions check`'s terms,
  the same rule as one of theirs (a paragraph or list item of five words or more, compared
  without case, code marks, emphasis or a final period: `Check.Text`'s rules, so the check
  and onboarding never disagree about what a duplicate is). Nothing else counts: a
  reworded rule is proposed, and the person reads the diff, since a duplicate in an
  `AGENTS.md` costs a few characters and a dropped rule is lost; a file's own repeats are
  its own business, as the check says. An added unit keeps the heading it was under,
  written once before it (a file's title only when nothing is there yet). A line that only
  imports the `AGENTS.md` being written (`@AGENTS.md`, Claude Code's way of pointing at
  it) is left out with a note, and a first heading naming the other tool's file (`# CLAUDE.md`)
  is written `# AGENTS.md`. When nothing is left to add, nothing is proposed: the file is
  skipped, "everything it says is in AGENTS.md already", which is also what a second run
  says once its proposal was written. Not chosen: a section-level merge (a matching
  heading would hide new text under it), or a model's paraphrase (#516: the onboarding
  step must be reviewable and the same files must give the same proposals).
- **Rules keep Decision 809's meaning.** A rule is Markdown with `description`, `globs` (a
  YAML list of quoted strings, which 809's line reader and YAML both read) and
  `alwaysApply: true`, then the body; only the keys that say something are written, and
  any other key is left out with a note. The front matter is read as 809 read `.mdc` files
  (a line per key; `globs` a comma-separated string, a list, or `-` lines). A directory's
  rule is read from the root once in `.troupe/rules/`, so its globs are rewritten from the
  root as 809 matched them from its directory (`src/**` under `web/` is `web/src/**`, a
  glob without a `/` is `web/**/<glob>`), and its `alwaysApply` becomes `globs:
  ["web/**"]`, which is when Cursor and 809 applied it; a description-only one is listed
  everywhere now, which its note says. Copilot's `applyTo` is its globs; `**`, `**/*` or
  `*` is `alwaysApply: true`. A rule with nothing that says when it applies is still
  proposed, with a note that no session joins it by itself. Names are made lowercase with
  dashes (`Docs Guide.mdc` is `docs-guide`); a directory's rule is named after the
  directory first (`web-style`); two that come out the same are told apart by a number,
  the root's Cursor rules first, then `.cursorrules`, then Copilot's, then the directories'.
  G26 reads them (Decision 828).
- **The writer's new targets.** `rules/<name>.md` joins the repository's whitelist (not
  the person's: no reader looks for `<config>/rules/`). And a third target, `:workspace`,
  writes `AGENTS.md` and only `AGENTS.md`, at the workspace's root or in a directory of it:
  every other name, a directory whose name starts with a dot (`.git`, `.troupe`, `.agents`,
  whose `AGENTS.md` is that directory's other file), a directory that is not there
  (onboarding makes none: an `AGENTS.md` is written beside the files it came from), and a
  path that resolves, links followed, outside the workspace or into a hidden directory are
  refused. Its provenance goes in the workspace's `.troupe/onboarded.json`, under a
  `workspace` section beside `files`, keyed by its path from the workspace (a skill's own
  `AGENTS.md` under `.troupe/skills/` cannot collide with it), and a `.troupe` that links
  out refuses the write before anything is written. Its source is a repository file, as
  `:repo`'s is. `drift/2` reads the section, and a manifest key that names no file
  onboarding writes there is not taken for a record, in either section.
- **A new `AGENTS.md` is its own question.** Every coding tool reads that file, so
  creating one commits every other tool too (#516's seventh decision). `plan/2` marks a
  proposal `question: :create_agents_md` when its `AGENTS.md` is not there, `:write`
  otherwise. `troupe onboard` asks it in its own words, "AGENTS.md is not there. Create
  it? Every coding tool reads AGENTS.md, not only Troupe.", and `--yes` never answers it:
  the file is left, the line says why, the summary counts it, and the run still exits 0.
  `--json` gives each proposal `question` (`create_agents_md` or `write`) and, with
  `--yes`, a left `AGENTS.md` `"written": false` with the reason, not counted as a failure.
  Adding to an `AGENTS.md` that is there is an ordinary proposal, shown as "adds to the
  one that is there". The `onboard_write` tool's `target: "workspace"` asks always, as
  `target: "user"` does (`must_ask?/1`, whatever `auto_approve` or the profile says): the
  call cannot tell a new file from an addition before it runs, and an `AGENTS.md` is
  every tool's, so an unasked write to it is never right. The librarian's prompt tells it
  to make the call that creates one on its own, so the approval asks exactly that.
- **A session's start proposes, never writes.** `Troupe.Onboard.Notice.due/2`, asked by
  `Troupe.start_session/1` for a local session with no bundle on a machine no worker runs
  on, gives one `onboarding_suggested` event (additive to the protocol) or nothing. In a
  workspace with other tools' files, nothing onboarded (no `.troupe/onboarded.json`, no
  file recording where it came from) and nothing declined, it counts what `troupe
  onboard` would propose by kind (`instructions`, `rules`, `agents`, `commands`, `skills`,
  `workflows`, `mcp`), never the content, and says how to run it. It asks only the sources
  whose `found?/1`, a new optional callback of `Troupe.Onboard.Source`, finds their files
  at the workspace's root, so a workspace with none costs a few `stat` calls a start; a
  repository whose only other-tool file is nested is found by `troupe onboard` but not
  announced. The terminal UI shows the event's `message` as a line. Once per workspace
  and version: what was said is remembered in the state directory's `onboard.json`
  (`suggested`, keyed by the workspace's real path, with the versions said), beside the
  person's declines and never in the repository; onboarding the workspace or declining a
  proposal in it ends the first notice for good. Not chosen: a notice at every start
  until onboarded (noise in every session of a repository the person has decided to leave
  as it is), or remembering it in `.troupe/` (a write into the repository nobody asked for).
- **Versions.** `Troupe.Onboard.version/0` (1) is the version of the onboarding rules,
  raised in the pull request that changes what any source writes for the same files. Every
  file written records it as `imported_version` (last in a frontmatter, so the lines a
  drift finding names stay where they were; in a manifest entry). The manifest records,
  as `onboarding`, the version the workspace was onboarded under as a whole: set when the
  manifest is first written (every write now writes it, so it is the one place that says
  a workspace was onboarded) and raised only by `stamp/1`, which `troupe onboard` calls
  after a run that left nothing unanswered (`--json` without `--yes`, nobody to ask, or a
  new `AGENTS.md` `--yes` left, stamp nothing), never by one file's write, so the librarian
  bringing one file in under newer rules does not mark the rest current. A manifest from
  before versions is version 0. A file recorded under older rules from unchanged sources is
  left alone when the new rules would write the same content, and otherwise offered once
  as a diff, so a change of rules is shown and the person's own edits are not taken back
  unasked. A workspace onboarded under older rules is told, at a session's start, to run
  `troupe onboard` again, once per version, and `troupe instructions check` reports it as
  a finding of its own kind, `outdated`, on the manifest's `onboarding` line: it comes from
  `Troupe.Onboard.drift/2`, which the check already prints, so `check.ex` (Decision 828's
  slot) is not changed here; its `@type kind` does not list `:outdated` yet. The brief has
  its own: `Troupe.Memory.survey_version/0` (1), written as `survey` in `.troupe/memory.md`'s
  frontmatter whenever a brief is stamped as built or checked (`Memory.stamp/3`); a brief
  with an older one, or none, is told at a start to be written again with `/memory
  refresh`, in the same notice, once per survey version. Nothing re-runs either, and an
  older brief is not called stale: `memory_auto_refresh` still asks only for absent or
  stale ones (Decision 649's client rule).
- **The librarian.** Its prompt says what is in every prompt now (`AGENTS.md`,
  `.agents/AGENTS.md`, `.troupe/rules/`) and that other tools' files are not; its first
  step is an onboarding pass that finds them, reads them, and proposes each through
  `onboard_write` (an `AGENTS.md` addition that keeps what is there and repeats nothing,
  a rule with 809's front matter), and never creates an `AGENTS.md` but by a call of its
  own. The brief still never copies what `AGENTS.md` says (Decision 649), nor what the
  person did not let it onboard.
- **Not in this slice.** Reading `.troupe/rules/` and removing the run-time readers
  (Decision 828); the person's own `~/.claude/CLAUDE.md` or a `<config>/CLAUDE.md`, which
  the loader read as an alias of `<config>/AGENTS.md`, as a `:user` proposal; Claude Code's
  `.claude/CLAUDE.md` and `CLAUDE.local.md`; rules in folders under `.cursor/rules`; a
  notice for a repository whose only other-tool file is nested; the desktop app showing
  the notice; `instructions/check.ex`'s `@type` naming `:outdated`.
- **Proof:** `Troupe.Onboard.InstructionsTest` (the fixture with every kind of file: two
  `AGENTS.md` proposals and eight rules, their content, notes, `also_from` and hashes; the
  same files giving the same proposals; an existing `AGENTS.md`'s units, reworded with case
  and code marks, not proposed again and a new one added under its heading, as an
  ordinary write; a file all said already, a linked alias and a link out skipped with
  why; the files no tool reads there skipped; two rules of one name; Windows line endings
  kept; every proposal written with its provenance and version, the manifest's
  `workspace` section, and a second run proposing nothing; a change to `GEMINI.md`
  drifting on `AGENTS.md` and proposing only its new item; a declined new `AGENTS.md`
  leaving nothing; the writer's `AGENTS.md` refusals, a linked `.troupe` among them; older
  rules left alone on the same content and offered on another; `outdated` in the check
  until `stamp/1`, and one write not raising it), `Troupe.Onboard.NoticeTest` (in real
  sessions: one notice with the counts and nothing written, quiet at the next start and
  remembered in the state directory; nothing in a workspace without such files or on a
  pod; nothing once declined or onboarded; an older onboarding told once; an older brief
  in the same notice, and a brief built now carrying `survey`),
  `Troupe.Onboard.LibrarianTest`, `Troupe.Tools.OnboardWriteTest` (an `AGENTS.md` asked
  about with `auto_approve` on, then written with its record), and the TUI's
  `Troupe.OnboardCLITest` (the separate question and an addition's ordinary one, a second
  run's skipped lines; `--json`'s `question`, `--yes` leaving a new `AGENTS.md` and
  exiting 0; the version recorded only once every question is answered) and
  `Troupe.OnboardingNoticeTest` (the event as a line). On the chunk's tip a `CLAUDE.md`
  gave no proposal and a session over one emitted no notice.
