---
number: 798
title: A turn reads the instruction files once, as it begins, from the directories on the way to the workspace and to every file its conversation worked on, and follows a file's @imports five deep inside the repository
date: 2026-10-06
status: accepted
issue: 123
supersedes: [706]
paths:
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_core/test/troupe/instructions_test.exs
  - apps/troupe_core/test/troupe/instructions_prompt_test.exs
  - apps/troupe_gateway/test/troupe/gateway/context_test.exs
symbols:
  - Troupe.Instructions.focus/1
  - Troupe.Instructions.load/3
gist: Read as a turn begins, held for it; nested files follow the files worked on; found files and imports must really be inside the repo (or config dir)
---

Issue #123, the parity slice after Decision 706: a nested `AGENTS.md` on the path to
what is being worked on, and `@path` imports. 706 read one `AGENTS.md` (or alias) in
each directory between the repository root and the workspace, which for the usual
session, started at the root, is none: `frontend/AGENTS.md` never reached a session
that edited `frontend/` from the root. It read the files again before every model call,
and it read no imports. The aliases, the budget with the nearest kept whole, the event
and `context.get` were already there and stay as 706 made them.

- **Where the session works.** The workspace, and the directory of every file the
  agent's conversation has read, edited or written: the `path` of each `read_file`,
  `edit_file` and `write_file` call in it (`Troupe.Instructions.focus/1`), relative to
  the workspace or absolute, inside the repository root. Each such directory brings the
  file of every directory from just below the root down to it, parents before their
  children and siblings in name order, so the order is stable from turn to turn. Taken
  from the conversation rather than kept beside it, so nothing new is logged or folded:
  a restarted agent replays the same conversation and works in the same places, and a
  compaction, whose summary names no calls, leaves only what it kept. Not chosen: the
  directory the session was started in alone (706's, which misses the common case);
  `grep`, `glob` and `list_files` paths, which search a place rather than work in it;
  attaching a nested file to the tool result that first touches its directory, as
  Claude Code does, which takes effect within the turn but puts instructions in the
  conversation where the budget, the event and `context.get` cannot see them, and
  which 706 deferred together with `.cursor/rules` globs.
- **Read as a turn begins, held for the turn.** The agent reads the files when it takes
  an input and after a compaction, and every call of the turn sends the same system
  prompt; 706 read them before every call, so a file the agent edited in the middle of
  a turn, or a directory it opened, changed the system prompt in front of the cached
  conversation, and with focus that would be every new directory. This is Decision
  792's rule for the task list, at the same two points, and the part of 706 it
  supersedes. A `remember` the agent makes reaches the brief in the prompt at the next
  turn, not the next call, as the brief is read with the files. An edit still takes
  effect on the next turn.
- **Imports.** An `@` at the start of a line or after a space, then a path, outside a
  code span and a fenced block, with a sentence's closing punctuation taken off: what
  Claude Code reads. Resolved from the importing file's directory (`~/` is the home),
  read right after the file that names it, in that file's scope, and listed with
  `imported_by`. Five deep, as Claude Code counts its hops; each file read once in the
  whole load, so a cycle stops where it comes back and a file two scopes import is read
  at the first. A repository's files import only from inside the repository root and
  the person's own `<config>/AGENTS.md` only from inside `<config>`, both judged where
  the file really is, symlinks followed; so a repository cannot pull the person's
  `config.yaml`, keys and all, into a prompt that goes to a provider. An import not
  followed is named on its importer's `unfollowed` with `missing`, `outside`, `depth`
  or `cycle`; a word after an `@` that names no file and has no `/` or `.` is taken for
  a mention (`@alice`), not a missing file.
- **The budget, scope by scope.** #123 asks for a per-scope budget with the nearest
  scopes kept whole first. 706's one budget allotted nearest first is that, with a
  scope now a file and what it imports: the nearest scope takes what it needs first,
  and within a scope the file comes before its imports. What was cut or left out is in
  the `instructions_loaded` event and `context.get` with the prompt saying so, as
  before; never a silent drop.
- **A found file has the imports' edge too.** A repository's instruction file can no
  longer bring in a file from outside the repository. 706 read the file it found in a
  directory wherever that file really was, so an `AGENTS.md` that is a link (or sits
  in a directory that is a link) to a file elsewhere on the machine put that file into
  the prompt, and nested files on the way to every file worked on widen where that can
  happen. Now a file found under one of the four names is judged where it really is,
  as an import is: outside the repository root (outside `<config>` for the person's own
  `AGENTS.md`), it is not read, and it is listed with `status: outside`, its `size`,
  `chars` and `hash` empty, in the `instructions_loaded` event and `context.get`, with
  nothing of it in the prompt. It still hides the other names in its directory, as the
  first name found does. A link that stays inside the repository (`CLAUDE.md` pointing
  at `AGENTS.md`) is read as before. What this costs: the person's own `AGENTS.md`
  kept as a link into a dotfiles directory outside `<config>` is held to the same edge
  and not read, nor can it be imported from there; it has to be a file in `<config>`.
- **`context.get`** answers with the focus of the root agent's conversation, asked of
  the agent; a session that is asleep has none to ask and is answered for its
  workspace alone, since reading it wakes nothing. The TUI's `/context` prints the new
  entries as it prints any file, with their scope and size; it is not changed.
- **Not in this slice.** `.cursor/rules` globs, the wider opencode and Claude Code
  imports, the linter, `troupe init`, the organisation layer, and a nested file reaching
  the turn in which its directory is first opened.
- **Proof:** `Troupe.InstructionsTest` (a file the conversation worked on brings the
  files on its way and not others, the focus is the three calls' paths, imports in
  order and from their directory, outside a code span or fence, each once; five deep,
  a cycle, outside the repository, missing; a file and its imports one scope in the
  budget; a root and a nested `AGENTS.md` linked to a file outside are `outside` and
  not read, one linked inside is read), `Troupe.InstructionsPromptTest` (a repository with only a `CLAUDE.md`, a
  `GEMINI.md` or a copilot file needs no setup and an edit reaches the next turn; a
  nested file on the way to a file the turn read is in the next turn's prompt, and the
  system prompt is the same on every call of a turn in which the agent rewrote
  `AGENTS.md`; an import reaches the prompt and the budget's cut is in the event; the
  person's own file imports from `<config>`; the repository's and the person's own
  `AGENTS.md` linked outside reach no prompt and are `outside` in the event) and
  `Troupe.Gateway.ContextTest` (the nested file and the import, with scope and size,
  in `context.get`; a linked-out `AGENTS.md` listed as `outside`). All but the aliases
  fail on the chunk's tip; the three on linked-out files failed on this branch before
  the edge was added, the file's contents in the prompt.
