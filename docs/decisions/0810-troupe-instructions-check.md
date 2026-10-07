---
number: 810
title: "`troupe instructions check` reads the instruction files through the loader and reports contradictions between scopes, missing paths, missing programs and repeated rules, preferring a missed finding to a false one"
date: 2026-10-07
status: accepted
issue: 123
paths:
  - apps/troupe_core/lib/troupe/instructions/check.ex
  - apps/troupe_core/lib/troupe/instructions/check/text.ex
  - apps/troupe_core/test/troupe/instructions_check_test.exs
  - clients/tui/test/troupe/instructions_check_cli_test.exs
  - clients/tui/lib/mix/tasks/troupe.xref.ex
symbols:
  - Troupe.Instructions.Check.run/2
  - Troupe.Instructions.Check.sources/1
  - Troupe.Instructions.Check.findings/2
gist: Files come from Troupe.Instructions.load/3, never a discovery of its own; what is not plainly a command or a repo path is passed over
---

Issue #123, item 10 ("a linter for the rules themselves") with a first slice of item 14
("verification over trust"). A repository's instruction files reach every prompt
(Decisions 706, 798, 806), and nothing told a team when two of them disagreed, when a
rule named a file that had moved, or a command whose program the machine does not have.
`troupe instructions check [--workspace DIR] [--json]` does, one line per finding with
its file and line, and exits 0 for none, 1 for any and 2 when the workspace cannot be
read, so a repository can run it in CI on its own files.

- **The loader's files, and only the loader's.** The check is `Troupe.Instructions.Check`
  in core, beside the loader, and it asks `Troupe.Instructions.load/3` which files a
  session reads, as a session that had worked on every file under the workspace would:
  the focus is each file a walk of the workspace finds, leaving out `.git`, what
  `.gitignore` hides and a directory with a `.git` of its own (a submodule, a worktree,
  another repository). So a nested `AGENTS.md` is checked wherever it is, an alias the
  loader skipped or a file it would not read (`outside`) is not, imports come in their
  importer's scope, and whatever the loader learns to read later (`.cursor/rules`) comes
  with it without a change here. Each file the loader read is read again, whole, for its
  lines, since the loader trims what it puts in the prompt. The brief is Troupe's own
  and not checked. Not chosen: walking the directories for the four names itself, which
  forks the discovery and checks files no session reads.
- **Contradictions are between scopes, within an ecosystem.** A command's subject (test,
  build, lint, format, run) and its ecosystem are read from a short list (`npm test`,
  `pnpm test`, `yarn test`, `bun test`, `mix test`, `cargo test`, `go test`, `pytest`,
  `ruff check`, `black`, ...), after its wrappers (`mise exec --`, `uv run`, an
  assignment, a package manager's `-C dir`) are taken off. A scope is the loader's
  (`user`, `root`, one per nested directory; a file and what it imports are one), and it
  is held to the nearest scope read before it whose work contains its own and that names
  the same subject in the same ecosystem: the root holds every nested scope, the
  person's own file holds everything, siblings hold nothing. The two disagree when they
  name no command in common. So the root's `npm test` and `frontend/AGENTS.md`'s `pnpm
  test` are a finding on the nearer file's line, naming the other; a root's `mix test`
  and `frontend/`'s `pnpm test` are two parts of a repository; a root that names both
  `npm test` and `pnpm test` agrees with a `frontend/` that names one. Not chosen: any two
  scopes naming different commands for a subject, which flags every polyglot monorepo;
  #114's decision model, which would need a model call for a check that must run offline
  and in CI.
- **A path is checked only when it reads as one here.** In a code span: one starting
  `./` or `../`, or with a slash that ends in one, names a file with a known extension,
  or starts with a directory that exists. In a link: any relative target (a leading `/`
  is the root's). Resolved from the file's directory and from the root; one that leads
  out of the repository is not judged. A path that is not there is still no finding when
  the repository has it under another directory (`client/link.ex` written after
  `lib/troupe/`) or `.gitignore` hides it (`_build/`). A bare file name (`an AGENTS.md`)
  is a kind of file as often as a file here, and a word with a slash is a branch
  (`origin/main`), a package or a media type as often as a path, so neither is checked.
  An `@` import the loader found `missing` is a finding on its importer's line. The
  person's own file names paths for every repository, so its paths are not judged here.
- **A command is checked only where it is plainly one.** A code span that starts with a
  program from a short list of build tools (`npm`, `pnpm`, `mix`, `cargo`, `go`, `mise`,
  `make`, ...) and has an argument (`pytest` and `make` alone count); every line of a
  fenced block marked as a shell, after its prompt, comment and assignments, split at
  `&&`, `||`, `;` and `|`; a block with no language held to the spans' list; a console
  block's lines after a prompt; no other language. The program is looked for on the
  `PATH` a session's commands get (`Troupe.Reaper.child_env/0`: in a release, without the
  release's own runtime), once per file. Not looked for: the shell's own words and
  builtins, the tools every shell has (`ls`, `grep`, `curl`), PowerShell's cmdlets, and
  the platform's package managers (`apt-get`, `brew`, `winget`), which say how to set a
  machine up rather than what the repository runs. Not done yet: running the command, or
  asking the program whether the subcommand exists (`mix check`); a program found is
  taken as the command working.
- **A rule said twice** is a paragraph or a list item of at least five words, compared
  without its marks, case and closing full stop, outside fenced blocks, headings and
  tables. Its first appearance in the order the files are read stands, and each later
  file that says it again is a finding pointing back. Twice in one file is not, and a
  skipped alias (a `CLAUDE.md` that copies `AGENTS.md`) is not read, so it repeats
  nothing.
- **Prefer missing a finding to a false one.** Each detector's narrowness above is that
  choice: a check that cries wolf on a repository's own files is switched off, and one
  that is quiet where it is unsure can be widened later, case by case, from the files it
  missed. The installed build's run on this repository found, in `clients/tui/CLAUDE.md`,
  `mise` missing from a Windows machine's PATH (true there: its toolchain is in WSL) and
  two paths, `.troupe/config.yaml` (meaning any workspace's) and `feature/` (meaning
  anybody's worktree), which the rules above still take for this repository's; the
  files were left to say otherwise, not the rules widened for them.
- **The TUI reaches it as a door.** `troupe instructions check` runs in the TUI's VM,
  reading the files as `troupe config --explain` and `troupe doctor` do, with no daemon;
  `Troupe.Instructions.Check` joins the harness modules `mix troupe.xref` lets the TUI
  call, as `Troupe.Doctor` did. `--json` is the same as one object: `workspace`, `root`,
  `files` (each with `file`, `path` and `scope`) and `findings` (each with `file`,
  `path`, `line`, `kind` and `message`).
- **Proof:** `Troupe.Instructions.CheckTest` (the planted contradiction, with the line
  and the text; a fenced block, a wrapper and a package manager's options; another
  ecosystem, a command in common, siblings and a file with its import, none a
  contradiction; the nearest scope that names the subject; the person's own file; paths
  in spans and links from the file's directory and the root, an import the loader found
  missing; what only might be a path, a path named under another directory and one
  `.gitignore` hides, none a finding; a missing program once per file from a span and a
  shell block, and no builtin, cmdlet, script path, prose word, other language or
  console output looked for; a rule repeated in another file, and not twice in one, nor
  in a skipped alias; a clean repository, `--json`, exit 2, no files, a hidden directory
  and a nested repository, a workspace below the root) and
  `Troupe.InstructionsCheckCLITest` in the TUI (the command line parses with
  `--workspace` and `--json`, the planted contradiction exits 1 as text and as JSON, a
  clean workspace 0, an unreadable one 2), which failed on the chunk's tip with the
  command line refused. The installed build's run on a scratch repository with each
  finding planted, and on this repository, is on the pull request.
