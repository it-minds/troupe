---
number: 706
title: A repository's own instruction files are read into every prompt, from disk at every turn, in the order the other tools read them, and one table says what got in
date: 2026-09-27
status: accepted
issue: 123
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/test/troupe/agent/loop_test.exs
  - apps/troupe_core/test/troupe/instructions_prompt_test.exs
  - apps/troupe_core/test/troupe/instructions_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/context_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
gist: A repository's own instruction files are read into every prompt, from disk at every turn, in the order the other tools read them, and one table…
---

Issue #123, its first slice. `AGENTS.md` is the file the tools settled on,
and a repository that has one has told agents how to work in it; Troupe read none
of it. The only mention was the librarian's prompt, which told that one agent to
fold `AGENTS.md` into the brief, so a repository's rules reached a session only as
a cheap model's paraphrase, only if somebody ran the librarian, and an edit changed
nothing until the brief was rebuilt. `Troupe.Instructions` now reads them: the
person's own `<config>/AGENTS.md`, the repository root's (the nearest directory
with a `.git`, so a worktree reads its own checkout's), one in each directory
between the root and the workspace, and the brief last. Every file applies and the
nearer comes later in the prompt, which is how "the nearest wins" is put to a
model. In one directory `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and
`.github/copilot-instructions.md` are the same file under other tools' names: the
first that exists is read, the rest are named as skipped.
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
- **Not in this slice.** `.cursor/rules` globs, `@path` imports, a nested
  `AGENTS.md` below the workspace (attached per file, the same mechanism as the
  globs), the wider opencode and Claude Code imports, the linter, proposed edits
  to `AGENTS.md`, the organisation layer, `troupe init`, command verification, and
  a GUI view of the provenance.
- **Proof:** `Troupe.InstructionsTest` (order, aliases and what is skipped, the
  budget with the nearest whole first, the root without and with a `.git` file,
  the digest), `Troupe.InstructionsPromptTest` (a repository with only an
  `AGENTS.md` and no Troupe setup reaches the prompt, an edit reaches the next
  turn, one event per change and none for a turn that read the same, the person's
  own file first and the brief last, the prompt names exactly what the provenance
  lists), `Troupe.Gateway.ContextTest`, and the installed build on a scratch
  repository, on the pull request.
