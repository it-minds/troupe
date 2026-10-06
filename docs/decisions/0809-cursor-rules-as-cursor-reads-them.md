---
number: 809
title: A repository's Cursor rules are read as Cursor reads them, an always rule in every prompt, a glob rule from the turn after a file it matches is worked on, a description-only rule listed by its description, and each says why
date: 2026-10-07
status: accepted
issue: 123
paths:
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/test/troupe/instructions_test.exs
  - apps/troupe_core/test/troupe/instructions_prompt_test.exs
  - apps/troupe_gateway/test/troupe/gateway/context_test.exs
  - clients/tui/lib/troupe/client/instructions.ex
  - clients/tui/test/troupe/context_command_test.exs
symbols:
  - Troupe.Instructions.load/3
  - Troupe.Instructions.provenance/1
gist: "`.cursor/rules`: alwaysApply joins, globs join once a matching file is worked on, description-only is listed not joined; each rule says why"
---

Issue #123, its third parity item: `.cursor/rules/*.mdc`, the one format the Markdown
files cannot express, and the one 706 and 798 left out. Cursor reads a rule's front
matter (`description`, `globs`, `alwaysApply`) to decide when the rule joins the model's
context. Troupe read none of it, so a team's Cursor rules reached no prompt and
`/context` did not name them.

- **Where.** `.cursor/rules/*.mdc` in the repository root, and in each directory on the
  way to where the session works (798's directories: the workspace and the directory of
  every file the conversation worked on), as nested `AGENTS.md` files are, and as Cursor
  reads nested rules, which attach once files in their directory are referenced. Only the
  `*.mdc` directly in the directory, in name order. The legacy `.cursorrules` at the root
  only, before them, as an always rule with no front matter. Not in `<config>`: Cursor
  keeps a person's own rules in its settings, not in files. A rule comes after its
  directory's instruction file and that file's imports, in that directory's scope, so it
  is nearer than its directory's `AGENTS.md` in the prompt's order. In the budget each
  rule is a scope of its own, and the nearest is kept whole first (706).
- **When a rule joins.** By Cursor's four kinds. `alwaysApply: true` (Always) puts the rule
  in every prompt, whatever else the front matter says. `globs` (Auto Attached) put it in
  from the turn after the session first read, edited or wrote a file one of them matches,
  for as long as the conversation holds that call. That is 798's focus, taken from the
  conversation: a restarted agent sees the same, and a compaction that folds the call
  away takes the rule with it, as it takes a nested `AGENTS.md`. Read as a turn begins
  and held for the turn (798, 792), so a rule that becomes active mid-turn joins at the
  next turn and the system prompt in front of the cached conversation does not change
  within one. Not chosen: attaching the rule to the tool result that read the file,
  which takes effect within the turn but leaves it where the budget, the event and
  `context.get` cannot see it (798's reasons).
- **Description only (Agent Requested).** Cursor shows its agent the description and the
  agent fetches the rule when it judges the rule relevant. Here such a rule is listed in the
  prompt by its path and description (`Rule <path> (<scope>), to read when it applies:
  <description>`), with status `listed`, and the agent reads the file with `read_file`
  when the description fits; its body is not joined. The line counts against the budget,
  whole or not at all. Not chosen: naming it in `context.get` alone, which leaves the
  agent no way to know the rule exists, the silent rule #123 warns about; joining it
  whole, which makes it an always rule under another name. A rule with none of the three
  (Manual, which Cursor joins when someone `@`-mentions it) is not joined and is listed
  as `inactive`: Troupe has no `@rule` mention, and a person can still ask the agent to
  read the file.
- **The front matter.** Read a line per key, as Cursor writes it and YAML would not
  always read it (`globs: *.ts` is an alias to YAML): `globs` a comma-separated string
  (commas inside `{}` kept), a `[...]` list or a list of `-` lines, quotes taken off;
  `description` folded across indented lines; `alwaysApply` true when it says `true`. A
  file without front matter, or with one that is never closed, has none of the three.
- **Globs.** Taken from the directory that holds `.cursor`: the repository root for the
  root's rules, as Cursor has it, and a nested rule's own directory for its rules, which
  is how a package's `src/**` reads. `**` crosses directories, `*` and `?` do not,
  `{a,b}` is either. A glob without a `/` matches a file's name in any directory, as
  `.gitignore` reads it and as rules written `*.tsx` expect; one ending in `/` matches
  everything under it; one that does not compile matches nothing. Matched against the
  paths as the calls named them, from that directory, without case on Windows.
- **Why, in words.** Every rule says why it applies or why not. A rule in the prompt has
  `applies` (`always applied`; `applied: src/a.ts matches src/**/*.ts`, or `... under
  web/` for a nested one). A rule not in it has `reason`: `applies when a file matching
  src/**/*.ts is read or edited`, `requested by description only: listed in the prompt,
  not joined`, `not joined: no alwaysApply, globs or description`, or the budget's or
  the edge's, as any file has. 806 stands: `reason` is null for a file whose contents
  reached the prompt, and a listed rule's contents did not, so it has one. `/context`
  prints `applies` after the characters (`.cursor/rules/ts.mdc (root) 7, applied:
  src/a.ts matches src/**/*.ts`) and `reason` as it prints any (TUI Decision 148). `rule`
  carries the front matter as read (`apply`: `always`, `globs`, `requested` or `manual`;
  `globs`, `description`, and `matched`, the file a glob matched), null for every other
  file, for a program, `troupe instructions check` among them, to read.
- **The edge.** A rule is confined as every other file is (798): one that is really
  outside the repository, through a link, is `outside` and not read. A `.cursor/rules`
  directory that is really outside is listed once as `outside` and not looked into, so
  not even the names of the files there reach the log. A rule's `@` is not followed as
  an import: Cursor takes it as a file to attach, not an instruction file, and following
  it from `.cursor/rules/` would resolve it in the wrong place.
- **What is left of the budget** is what the files nearer in did not take. The allotment
  subtracted the length of each file's text, which until now was always what the file
  took or more than was left; a listed rule left out whole would have spent the budget
  of the files farther out, and now leaves it to them.
- **Additive.** New keys `rule` and `applies` on every file, new `status` values
  `inactive` and `listed`, new entries in `files`; neither the result of `context.get`
  nor the event's `files` items are in the committed schema. `load/3`, `to_prompt/1`,
  `provenance/1,3` and `focus/1` keep their shape.
- **Not in this slice.** Rules in subdirectories of `.cursor/rules`, `.md` rules, a rule's
  `@` files, and the `/context` command's own help text, which still names only the
  Markdown files (the CLI reference is regenerated from it).
- **Proof:** `Troupe.InstructionsTest` (an always rule joins and the legacy file with it,
  a glob rule is `inactive` with its reason until a file worked on matches, then joins
  saying which file and glob; a description-only rule is `listed` by its description; a
  rule with neither, or no front matter, is `inactive`; the front matter's forms, braces,
  a name in any directory, a path from the root, a directory; a nested `.cursor/rules`
  once the session works under it, its globs from there; a rule linked outside and a
  `.cursor/rules` linked outside not read, the second's files not named; the budget,
  with a listed rule whole or out and its room left to farther files),
  `Troupe.InstructionsPromptTest` (in a real session: the always rule in the first
  prompt, the glob rule in the turn after the one that read a matching file and in the
  turn after that, the description-only rule listed and its body never in the prompt,
  the events saying why), `Troupe.Gateway.ContextTest` (`context.get` before and after
  a turn that read a matching file, each rule with `applies` or `reason`) and the TUI's
  `ContextCommandTest` (`/context` against the harness with the three kinds of rule, and
  a joined rule's line). Every one failed on the chunk's tip: the always rule was not in
  the prompt.
