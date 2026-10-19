# Instruction files and onboarding

A repository that carries an `AGENTS.md` has told coding agents how to work in it, and
Troupe reads it as the other tools do. What other tools keep in files of their own
(`CLAUDE.md`, Cursor's rules and the rest) is brought into Troupe's files once, by
`troupe onboard`, and read from there.

## What every agent is given

These, in this order, each read from disk as a turn begins, so an edit takes effect on the
next turn. They go with the first turn's message, and again with a later one's when one
changed, so the system prompt stays the same all session; with `system_prompt: per_turn`
they open the system prompt instead, rewritten each turn.

1. `<config>/AGENTS.md`: your own, for every repository.
2. `AGENTS.md` at the repository root (the nearest directory with a `.git`; a worktree
   reads its own checkout's).
3. `AGENTS.md` in each directory between the root and where the session works, parents
   before children. Where the session works is the directory it started in and the
   directory of every file its conversation has read, edited or written, so
   `frontend/AGENTS.md` applies from the turn after the agent first opened something under
   `frontend/`.
4. The project brief Troupe's own agents write: the commands and conventions among the
   repository's facts (`.troupe/memory/facts.jsonl`), each that may no longer be true
   marked so, and a line naming the `recall` tool for the rest.

An `.agents/AGENTS.md` at the root, or in one of those directories, belongs to its
directory and is read right before that directory's own `AGENTS.md`, so where the two
disagree the directory's own wins; `/context` names it with its directory's scope
(`.agents/AGENTS.md (root)`). Your own `<config>` has none.

Every file applies. A file below the root is about the work under its directory, and where
two disagree the nearer wins ([which one wins](configuration.md#which-one-wins)).

The brief is the repository's, kept in its checkout, and a worktree or a folder of the
repository reads it. Which folders are the repository's follows git: one it tracks, or
would add, is; one it ignores is a workspace of its own, as a directory in no repository
is. Such a folder keeps its own brief, and a session there does not start the librarian by
itself (`memory_auto_refresh`), so it never rewrites the brief of the repository around it;
`/memory refresh` still writes the folder's own. The instruction files are read as above,
up to the nearest `.git`, in either.

### What is not read

Other tools' files are not read: a `CLAUDE.md` or `GEMINI.md` in one of those directories,
Copilot's `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md`
at the root, and Cursor's `.cursorrules` and `.cursor/rules/*.mdc`. Each is listed in the
session's log and `/context` as `not read: run troupe onboard`, and once
[onboarded](#onboarding-another-tools-files) as `not read: onboarded into AGENTS.md`. So a
repository with only a `CLAUDE.md` gives a session nothing until it is onboarded. A
Copilot file below the root never counted, since Copilot reads its file at the root only,
and says so: `not read: Copilot's file counts only at the root`.

A file that is a link outside the repository (outside `<config>`, for your own
`AGENTS.md`) is not read, and `context.get` and the session's log list it as `outside`;
the same goes for `.troupe/memory.md`, which is then neither read nor written. A file that
is there and cannot be read is `unreadable`. Every file left out has a `reason` in words,
which `/context` prints: `not read: outside the repository`, `not read: permission
denied`.

### Imports

A file can pull in another with `@path/to/file.md`, on a line of its own or in a
sentence, as Claude Code's do. The path is taken from the importing file's directory
(`~/` is your home); the imported file is read right after the one that names it, and may
import again, five deep. Each file is read once, so a cycle ends where it comes back
round. An `@` inside a code span or a fenced block is not an import. A repository's files
import only from inside the repository, and your own `AGENTS.md` only from inside
`<config>`. An import not followed (`missing`, `outside`, `depth`, `cycle`) is named on
the file that asked for it in `context.get` and the session's log, and `/context` prints
it after that file (`@docs/gone.md (root) import not followed: missing`).

### Rules

A repository's rules are Markdown files in `.troupe/rules/`, each with front matter that
says when it applies, as Cursor's rules do:

```markdown
---
description: TypeScript in the web app
globs: src/**/*.ts, *.tsx
alwaysApply: false
---
No `any`; prefer `unknown` and narrow it.
```

Each `.troupe/rules/*.md` at the root, and in a directory on the way to where the session
works, comes right after that directory's own file, in name order:

- `alwaysApply: true` puts it in every prompt;
- `globs` (a comma-separated string or a list) put it in the prompt from the turn after
  the agent first read, edited or wrote a file one of them matches, for as long as the
  conversation holds that call. A glob is taken from the directory that holds `.troupe`,
  and one without a `/` matches a file's name in any directory;
- a rule with only a `description` is listed in the prompt by it, and the agent reads the
  file when the description fits the work;
- a rule with none of them is not used.

`/context` says of each rule why it applies (`always applied`, `applied: src/a.ts matches
src/**/*.ts`) or why not (`applies when a file matching src/**/*.ts is read or edited`,
`requested by description only: listed in the prompt, not joined`). Rules share the
budget below and are held to the repository's edge as every other file is; an `@` in a
rule is not followed.

### The budget

The files share one budget, `instructions_max_chars` (16,000 characters), a file and what
it imports counting as one scope. The nearest scope is kept whole first; a file the
remainder cannot hold is cut, or left out, and the prompt says so where it happened. The
brief has its own, `memory_max_chars`. `/context` in the TUI, and `context.get` over the
protocol, list every file in force with its scope, its size, what reached the prompt and
its share of the budget; the session's `instructions_loaded` event records the same, what
was cut included, whenever what was read changed.

## Checking them

`troupe instructions check [--workspace DIR] [--json]` checks every file a session in the
workspace would read wherever it worked, nested ones, `.troupe/rules` and imports
included, and none of the other tools' files. It prints a line for each finding, with the
file and the line:

```
frontend/AGENTS.md:3: contradiction: how to run the tests: `pnpm test` here, `npm test` in AGENTS.md:3
AGENTS.md:12: path: `docs/setup.md` does not exist
AGENTS.md:20: command: `mise` is not on the PATH (`mise exec -- mix test`)
frontend/AGENTS.md:9: duplicate: the same rule as AGENTS.md:5
```

- **contradiction**: two files, one of which applies inside the other, name different
  commands for the same job (test, build, lint, format, run) in the same ecosystem, and no
  command in common. A root's `mix test` and `frontend/`'s `pnpm test` are two parts of
  one repository, not a contradiction, and two sibling directories never are.
- **path**: a path in a code span or a link that is not there, from the file's own
  directory (for an `.agents/AGENTS.md` or a rule, also from the directory holding its
  `.agents` or `.troupe`) or from the root, and an `@` import that names no file. A span
  counts as a path when it starts with `./` or `../`, or has a slash and ends in one, names
  a file with an extension, or starts with a directory that is there; a bare file name, a
  branch like `origin/main` and a URL are not checked.
- **command**: a command in a code span, or in a fenced block marked as a shell (or with
  no language), whose program is not on the `PATH`. A span counts as a command when it
  starts with a known build tool (`npm`, `pnpm`, `mix`, `cargo`, `go`, `pytest`, `mise`,
  `make` and their like); the shell's own commands and the platform's package managers are
  not looked for.
- **duplicate**: a paragraph or list item said again in another file.
- **drift**: a file `troupe onboard` wrote whose source, or another file it was made
  from, has changed or gone since (its `imported_from`, `imported_hash` and
  `imported_also`); `troupe onboard` shows what changed.
- **outdated**: the workspace was onboarded under older onboarding rules than this
  build's (`.troupe/onboarded.json`'s `onboarding`); `troupe onboard` shows what they would
  write now, and a run that answers every question records the new version.

It would rather miss a finding than make a false one. It exits 0 when it finds nothing, 1
on a finding and 2 when it cannot read the workspace, so a repository can run it in CI;
`--json` prints the same as one object, with `files`, `onboarded` and `findings`. Your own
`<config>/AGENTS.md` is checked with the rest, except for paths, which it names for every
repository.

## Onboarding another tool's files

What another coding tool keeps for a repository, or for you, is brought into Troupe's own
files once, and sessions read Troupe's files from then on. `troupe onboard [--workspace
DIR]` asks each source Troupe knows what it would write, and shows each file as a diff
against what is there:

```
.troupe/agents/reviewer.md: new, from .claude/agents/reviewer.md
  note: tools: WebSearch left out, Troupe has no such tool
+ ---
+ description: Reviews the change on this branch
+ tools: [read_file, grep]
+ imported_from: ".claude/agents/reviewer.md"
+ imported_hash: "9f2c..."
+ imported_at: "2026-10-09T12:00:00Z"
+ ---
+ You review code.
Write .troupe/agents/reviewer.md? [y/N]
```

What it brings in:

- **Instruction files.** A `CLAUDE.md` or `GEMINI.md`, at the root or in a directory, and
  Claude Code's `.claude/CLAUDE.md` and Copilot's `.github/copilot-instructions.md` at the
  root, are proposed as additions to the `AGENTS.md` in the same directory: that file stays
  as it is, and only what it does not already say is added after it, under the heading it
  was under. Said already means the same text, spaces aside, or what `troupe instructions
  check` calls a duplicate; anything reworded is proposed, and you read the diff. A line
  that only imports `AGENTS.md` (`@AGENTS.md`) is left out. With nothing left to add,
  nothing is proposed and the file is listed as `skipped:`, saying so.
- **Your own instruction files.** Your config directory's `CLAUDE.md` and `GEMINI.md`, and
  Claude Code's `~/.claude/CLAUDE.md`, are proposed the same way as additions to your own
  `<config>/AGENTS.md`, never to a repository's. `CLAUDE.local.md` is yours and usually not
  committed, so it is proposed nowhere: move what it says into `<config>/AGENTS.md` by
  hand, or keep it.
- **Rules.** Cursor's `.cursor/rules/*.mdc` (the root's and a directory's), its legacy
  `.cursorrules`, and Copilot's `.github/instructions/*.instructions.md` become
  `.troupe/rules/<name>.md`, with Cursor's front matter, `description`, `globs` and
  `alwaysApply`, meaning what it meant there. A directory's rule has its globs written from
  the root (`src/**` under `web/` is `web/src/**`); Copilot's `applyTo` is its globs, and
  `applyTo: "**"` is `alwaysApply: true`.
- **opencode's `instructions`.** The files `opencode.json` names in `instructions`, by path
  or glob, are proposed as additions to the root's `AGENTS.md`, after what the other tools'
  files add, without their front matter; one whose front matter scopes it with `globs`
  becomes a rule instead. A URL, a file outside the workspace, an `AGENTS.md` (Troupe reads
  those itself) and another tool's file onboarded on its own are listed as `skipped:`,
  saying why.
- **Agents and commands**, Claude Code's and opencode's, become `.troupe/agents/` and
  `.troupe/commands/` files.

**Creating an `AGENTS.md` is a question of its own.** Every coding tool reads that file,
so when the directory has none, `troupe onboard` asks `AGENTS.md is not there. Create
it?`, and `--yes` never answers it: the file is left for a run at a terminal, and the
summary says so. `--json` marks each proposal with `question`, `create_agents_md` for a new
`AGENTS.md` and `write` for the rest, and with `--yes` gives a new `AGENTS.md`
`"written": false` and the reason, which does not fail the run. Adding to an `AGENTS.md`
that is there is an ordinary proposal.

### What it writes

Only what you answer yes to, one file at a time, in two places: the workspace's
`.troupe/`, from the repository's files, and your config directory, from files in your
home directory, never one into the other. There only `agents/<name>.md`,
`commands/<name>.md`, `rules/<name>.md` (the repository's), `skills/<name>/...`,
`workflows/<name>.json`, `mcp.json` and your own `AGENTS.md`; and besides those, an
`AGENTS.md` at the workspace's root or in one of its directories that is there and not
hidden. A file that would land anywhere else, through a `..` or a `.troupe` that links
elsewhere, is refused.

Each file written records where it came from: `imported_from`, `imported_hash`,
`imported_at`, `imported_also` for any other file it was made from (an agent's
permissions in `.claude/settings.json`, say, or the `GEMINI.md` an `AGENTS.md` took from
too), and `imported_version`, the version of the onboarding rules that wrote it. A
Markdown file keeps them in its front matter; anything else, and an `AGENTS.md`, which is
read whole into the prompt, in `onboarded.json` (the workspace's `.troupe/onboarded.json`
for an `AGENTS.md` of the workspace's). A file a source found and made nothing of is
listed first, as `skipped:` with the reason.

Run again, it proposes nothing until a source changes: a file onboarded from an unchanged
source is left alone, your edits to it included, and one you said no to is not asked about
until its source changes (`--all` asks again; the answer is kept in Troupe's state
directory). A changed source is offered as a diff against the file you have; nothing is
overwritten unasked. `--yes` writes every proposal without asking; `--json` prints them as
one object and writes nothing without `--yes`. It exits 1 when a proposal was refused or a
write failed, and 2 when there was nobody to ask.

Inside a session, an agent whose profile names the `onboard_write` tool writes the same
files with it, asking before each one; into your config directory, and into an
`AGENTS.md`, it asks even with `auto_approve` on, since what lands there runs in every
session unasked, or is read by every tool.

### When a session offers it

Onboarding proposes by itself and never writes by itself. A session in a git repository
that has other tools' files and nothing onboarded says in one line what `troupe onboard`
would bring in (`1 AGENTS.md, 2 rules and 1 agent`), and the TUI and the desktop app ask
about it as the session starts, before the librarian: `Onboard 3 files from Claude Code
and Cursor into Troupe's own? [Y/n/r]`. Yes writes them, then asks on its own about each
`AGENTS.md` that is not there yet; `r` shows each file as `troupe onboard` does and asks
for it; no leaves them all.

The onboarding rules have a version, recorded in `.troupe/onboarded.json` as `onboarding`
when a workspace is first onboarded and again once every question is answered. In a
workspace onboarded under older rules than its build's, a session asks `Onboarding rules
changed since this repository was onboarded (v1 to v2). Re-run now? [Y/n]`; where an older
librarian's survey wrote the brief (its `survey` in `.troupe/memory.md`), it asks whether
to rewrite it; Yes is the default for both. Only then does the librarian start, so it
reads what onboarding wrote. Each is asked at every start until answered, and a no is
remembered for that version in Troupe's state directory (`onboard.json`). Nothing re-runs
by itself, and a headless run (`troupe run`) prints the line and asks nothing.
