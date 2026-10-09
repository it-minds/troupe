---
number: 823
title: Other tools' files are onboarded through one writer that reaches only the workspace's .troupe/ and the person's config directory, judged by real path, and every file it writes records where it came from, so troupe instructions check can say when that source changes
date: 2026-10-09
status: accepted
issue: 516
paths:
  - apps/troupe_core/lib/troupe/onboard.ex
  - apps/troupe_core/lib/troupe/onboard/source.ex
  - apps/troupe_core/lib/troupe/tools/onboard_write.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/instructions/check.ex
  - apps/troupe_core/priv/agents/librarian.md
  - apps/troupe_core/test/troupe/onboard_test.exs
  - apps/troupe_core/test/troupe/tools/onboard_write_test.exs
  - clients/tui/lib/troupe/cli/onboard.ex
  - clients/tui/lib/mix/tasks/troupe.xref.ex
  - clients/tui/test/troupe/onboard_cli_test.exs
symbols:
  - Troupe.Onboard.Source
  - Troupe.Onboard.plan/2
  - Troupe.Onboard.write/3
  - Troupe.Onboard.drift/2
  - Troupe.Tools.OnboardWrite
gist: One writer, two roots by real path, Troupe's kinds of file only; provenance in frontmatter or onboarded.json; nothing overwritten unasked; drift from records
---

Issue #516, slice 3, and the command that drives it. #516 decided that other tools'
configuration stops being read at runtime and is onboarded once into Troupe's own files.
The maintainer decided for this chunk that the writer is a dedicated tool confined to
`.troupe/` and the config directory, as `remember` is (Decision 649), not `write_file`
behind an approval, which would hand the model a free path argument. What was there: no
tool the librarian has could write `.troupe/agents/x.md` (its list is `read_file`,
`list_files`, `grep`, `remember`, `finish`), `write_file` could reach any path in the
workspace with nothing recorded about where the content came from, and `troupe onboard`
was an unknown command line.

- **One writer, two roots, Troupe's kinds of file.** `Troupe.Onboard.write/3` is the only
  thing that writes an onboarded file, for the command line and the tool alike. A file is
  `:repo`, under the workspace's `.troupe/`, or `:user`, under the person's config
  directory, and only of a kind Troupe reads there: `agents/<name>.md`,
  `commands/<name>.md`, `skills/<name>/...`, `workflows/<name>.json`, `mcp.json`, and for
  `:user` the person's own `AGENTS.md`. Not `config.yaml` or `config.local.yaml`, which
  have their writer (Decision 686) and hold the keys that decide what may run; not
  `credentials.json`, the brief or `onboarded.json`. A list of what may be written, not of
  what may not: a file added to the config directory later is not writable by default.
  A path with `..`, an empty or `.` part, a backslash, a leading `/`, `~` or drive letter,
  or a character a file name cannot have everywhere is refused before anything is read.
- **Judged where it really is.** The file is resolved with `Troupe.Workspace.real_path/1`,
  links and junctions followed, and must be under the workspace's real path joined with
  `.troupe`, or under the config directory's real path: a `.troupe` that is a link, to
  anywhere, an `agents` in it that links out of `.troupe/` (even into the workspace), or
  a file that is a link out, is refused with a sentence naming where it resolves. This is
  Decision 798's edge for reading the brief and #512's rule, applied to what Troupe
  writes; the readers' half of #512 is its own issue. The file is written at the real
  path it was judged by, to a temporary file beside it renamed over it, inside a VM-wide
  transaction on that path.
- **A repository's file into the repository, the person's own into their config.** A
  `:repo` proposal's source is relative to the workspace and really inside it; a `:user`
  one starts `~/` and is really inside the home directory. One never crosses into the
  other, so a clone cannot write the config directory every session reads, and the
  person's files never land in a repository (#516's mapping table). The tool also refuses
  `target: user` to an agent defined by the workspace (`.troupe/agents/`), whatever
  permission that agent's file gives itself (#511), and refuses on a pod (a session with a
  bundle), where the bundle's files are the ones that count.
- **Provenance: frontmatter for Markdown, `onboarded.json` for the rest.** Every file
  written records `imported_from` (the source as the proposal names it), `imported_hash`
  (the lowercase hex sha256 of the source's bytes) and `imported_at` (UTC, to the second).
  In a Markdown file they are three keys at the end of its YAML frontmatter, quoted, any
  older ones replaced, a frontmatter added when there was none: agents, commands and
  skills are read as frontmatter and body, and their parsers ignore keys they do not know,
  so the keys cost nothing and travel with the file into a commit. Any other file, and a
  root `AGENTS.md`, which the loader reads whole into the prompt, records them in a sidecar
  `onboarded.json` at its root (`{"version": 1, "files": {"<path>": {...}}}`, sorted by
  path), not a reserved key: one rule for JSON, YAML and whatever comes next, and
  `mcp.json`'s own reader is left as it is. The sidecar is written after the file, so a
  failure between the two leaves a file with no record, proposed again and never taken for
  unchanged. Not chosen: a key inside each JSON file (a different rule per format, and a
  key `Troupe.MCP.Local` would have to learn to ignore), and a sidecar for Markdown too
  (two places to read one fact).
- **More than one file behind one written.** A proposal may carry `also_from`, a list of
  `%{source, source_hash}` for the other files its content was made from (a Claude Code
  agent's permissions come from `.claude/settings.json` too; an opencode agent takes the
  top-level `permission`; an inlined `{file:}`), each held to the same edge as `source`.
  They are recorded as `imported_also`, a list of `{"from", "hash"}` in path order (one
  line of JSON in a frontmatter, which YAML reads as it is; a list in `onboarded.json`),
  absent when there are none. A file is unchanged only when its source and every one of
  these are, a decline is remembered for all of them, and a change to any is a new
  proposal and a drift finding of its own ("imported with `.claude/settings.json`, which
  has changed since") on the `imported_also` line.
- **What a source passed over.** A source may export `skipped/2`, optional, naming each of
  the other tool's files it found and proposed nothing for, with the reason (linked out of
  the workspace, disabled, a name Troupe cannot take, a shadowed command); `plan/2` passes
  them on as `skipped` and `troupe onboard` lists them first, so a file the person expected
  is never missing without a word. They change no exit status: the source chose them.
- **The hash is taken, not trusted.** A proposal carries its source's hash, and the writer
  reads the source again and refuses one that does not match; the tool computes it itself
  and never takes one from the model. A source that is gone, a directory, or outside where
  it may be is refused with a sentence.
- **Nothing silent.** `Troupe.Onboard.plan/2` asks the registered sources and passes over
  a proposal whose file already records the same source and the same hash: the source has
  not changed since it was onboarded, so the person's own later edits to Troupe's file
  stand, which is what makes "a second run with nothing changed proposes nothing" true.
  Everything else is offered with a line diff against what the file holds (all `+` for a
  new one): a changed source, or a file onboarding did not write, which is never taken over
  without a yes. `accept/3` writes exactly what was shown (the same `imported_at`) and
  refuses when the file changed after it was shown. A no is `decline/2`: the source and
  its hash are remembered in the state directory (`<state>/onboard.json`, keyed by the
  file's real path), never in either root, and the proposal is not offered again until
  its source changes; `--all` offers it anyway. So a declined proposal leaves nothing
  where it would have gone, not even a directory, and the next run does not ask again.
- **Sources are modules, registered in one line.** `Troupe.Onboard.Source` is
  `@callback proposals(workspace, opts) :: [proposal]`, a proposal the plain map
  `%{target, path, content, source, source_hash, notes}` the chunk fixed between this slice
  and the next (and the optional `also_from`), `opts` carrying `home`; `skipped/2` is the
  optional second callback. A source only proposes; the writer checks, shows,
  writes and records. `Troupe.Onboard.sources/0` is `@sources` in `Troupe.Onboard`, empty
  in this slice, which #516's slice 4 fills with its agents and commands source; the
  `:onboard_sources` application setting replaces it for a test, or for a script driving a
  build, and no config file reaches it. A source that raises, or answers something that is
  not a list of maps, is a refusal naming it, and the other sources are still asked.
- **The tool: `onboard_write`, asks, named only.** The librarian's way to write the same
  files from a session: `target` (`repo` or `user`), `path` (relative to the root),
  `source` and `content`; it calls the same writer and logs an `onboarded` event (`target`,
  `path`, `file`, `source`, `source_hash`, `action`) in the session's log. Its default is
  `:ask`, unlike `remember`: `remember` reaches one file of notes, this one writes what
  decides what runs (an agent's tools and permissions, a command's prompt, an MCP server),
  so the person sees each file in the approval, and `auto_approve` is still the person's
  own choice. It is offered only to a profile that names it (`@named_only` in
  `Troupe.Tools`): the librarian does; `build` and every other agent with `tools: all` is
  neither offered it nor let call it, which also keeps its spec out of every build prompt.
  Its refusals are the writer's sentences, plus the two above (a pod, a workspace's agent
  writing the config directory).
- **`troupe onboard [--workspace DIR] [--yes] [--json] [--all]`** runs in the TUI's VM,
  as `troupe instructions check` does (Decision 810): it reads and writes files on this
  machine and needs no daemon, and `Troupe.Onboard` joins the harness modules `mix
  troupe.xref` lets the TUI call, so the decisions are the harness's and the TUI only asks.
  Each file is printed as its name, its status and source, the source's notes and the
  diff, then `Write <file>? [y/N]`, at a terminal only, read as `troupe bench --live`
  reads its question (TUI Decision 141). With nobody to ask it prints every proposal,
  writes and remembers nothing, and exits 2. `--yes` writes them all; `--json` prints them
  (`proposals` with `target`, `path`, `file`, `source`, `source_hash`, `status`, `notes`,
  `diff`; `refused`; `unchanged`; `declined`) and writes nothing unless `--yes` too. Exit
  1 for a refusal or a failed write. A workspace that is not a directory here is refused
  with 2: onboarding writes a local workspace, never a pod's.
- **Drift is read from the records, not found by a search.** `troupe instructions check`
  (Decision 810) gains a fifth kind, `drift`: `Troupe.Onboard.drift/2` reads the
  provenance back, from the frontmatter of the Markdown files in `agents/`, `commands/`
  and `skills/` under each root (links not followed) and from each root's
  `onboarded.json`, hashes each recorded source and reports, on the line of
  `imported_hash` (1 for the sidecar's files), one that has changed ("`troupe onboard`
  shows what changed") or is gone. The instruction files are still the loader's alone, as
  810 says; a record that names a source where none may be (a repository's file pointing
  outside the workspace) is passed over rather than read, so a repository cannot use the
  check to ask whether a file elsewhere on the machine has a given content. `--json` adds
  `onboarded` (`file`, `path`, `imported_from`), and the count line names the onboarded
  files when there are any.
- **Not this slice.** No source is registered yet (slice 4's agents and commands, and
  slice 2's instruction files); onboarding does not start by itself (#516's decision 4);
  the librarian's prompt is not rewritten to onboard (slice 2); the readers of
  `.troupe/agents`, `commands` and `workflows` are not yet held to the workspace's edge
  (#512's reading half); a workspace's agent that grants itself `onboard_write: auto` in
  an untrusted workspace is #511's, capped where a session reads it.
- **Proof:** `Troupe.OnboardTest` (a new agent proposed as a diff and written with the
  three keys, still parsed as the agent it is, and a second plan proposing nothing; a
  declined proposal leaving nothing in either root, not offered again, offered with `all`
  and again once its source changed; a changed source offered as a diff with the file
  untouched until accepted; a person's edit standing; a file changed after it was shown
  not overwritten; a file onboarding did not write offered, never taken; `mcp.json` and
  `AGENTS.md` recorded in `onboarded.json`; a failing source refused by name; a source's
  skipped files passed on; a file made from a settings file too recording it, unchanged
  until that file changes, then proposed again and drifting on its own line, and a wrong
  or outside `also_from` refused; every path
  refusal and both crossings refused with nothing written; a `.troupe`, an `agents` and a
  source that link out refused; drift on a changed and a gone source in `.troupe/` and in
  the config directory, in text and JSON, and a record pointing outside passed over),
  `Troupe.Tools.OnboardWriteTest` (the librarian's call waits for the approval, then
  writes the file with its provenance and logs `onboarded`; a denied call leaves nothing;
  `build` is neither offered it nor let call it; each refusal; a pod and a workspace's own
  agent refused), and the TUI's `Troupe.OnboardCLITest` (the command line; `--yes` through
  the runner with a source registered; a yes and a no, the diff and the notes printed, and
  a second run proposing nothing; a changed source offered as a diff and left as it was on
  a no, and `troupe instructions check` going from 0 to 1 with the drift line; nobody to
  ask; a refused proposal exiting 1; `--json` with and without `--yes`; a skipped file
  listed, a file made with a settings file too naming it and drifting when it changes; a
  missing workspace). On the chunk's tip all five of the tool's tests and all eight of the
  command line's failed: the librarian's call was refused before any approval, and
  `troupe onboard` was `unknown arguments: onboard`. The installed build's run on a
  scratch repository with a stub source is on the pull request.
