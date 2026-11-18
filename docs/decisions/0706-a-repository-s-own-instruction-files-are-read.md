---
number: 706
title: A repository's own instruction files are read into every prompt, from disk at every turn, in the order the other tools read them, and one table says what got in
date: 2026-09-27
status: accepted
issue: 123
paths:
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
gist: A repository's own instruction files are read into every prompt, from disk at every turn, in the order the other tools read them, and one table…
---

`AGENTS.md` is the file the tools settled on, and a repository that has one has told
agents how to work in it; Troupe read none of it. `Troupe.Instructions` now reads them:
the person's own `<config>/AGENTS.md`, the repository root's (the nearest directory with a
`.git`, so a worktree reads its own checkout's), one in each directory between the root
and the workspace, and the brief last. Every file applies and the nearer comes later in
the prompt, which is how "the nearest wins" is put to a model. In one directory
`AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `.github/copilot-instructions.md` are the same
file under other tools' names: the first that exists is read, the rest are named as
skipped.
- **Read every turn, cached by digest.** The agent reads the files before every
  model call and keeps a digest of what it read; an `instructions_loaded` event is
  written when the digest changed since its last turn and never otherwise. So an
  edit reaches the next turn, the log says which files each turn was read from,
  and a quiet log means the same files again. Not distilled once by the librarian,
  whose prompt still folds the same files into the brief — a follow-up stops it.
- **One budget, the nearest whole first.** `instructions_max_chars` (16,000) is
  shared by the instruction files; the nearest takes what it needs first, and a
  file the remainder cannot hold is cut where the prompt says so, or left out with
  a line saying so. The brief keeps `memory_max_chars`. Never a silent drop.
- **Provenance is a method.** `context.get` (`observe`, a session method a worker
  answers too) lists every file the next prompt is read from — scope, path, size,
  characters that got in, budget, share, status, what was cut, what was skipped,
  hash — read from disk when asked, as the next turn will read it, so it says what
  an edit will do; a past turn's read is its event. `/context` in the TUI prints
  it (TUI Decision 124). Nothing reaches the prompt from a file without appearing
  there: the loader that answers the method is the loader that builds the prompt.
