---
number: 148
title: "`/context` says why each file is left out, in `context.get`'s words, and puts each import not followed after the file that names it"
date: 2026-10-06
status: accepted
issue: 123
paths:
  - clients/tui/lib/troupe/client/instructions.ex
  - clients/tui/test/troupe/context_command_test.exs
gist: "`/context` prints a left-out file's `reason` as given, not a bare 0, and each unfollowed import in words; an answer without `reason` prints as before"
---

Issue #123, root Decision 806, D78's fifth item. `/context` printed a file left out as
`outside` as `AGENTS.md (root) 0`, which reads as an empty file, and an import that was
not followed not at all. Now each file left out is its own entry on the line, its path
and scope followed by the `reason` `context.get` gives it, as given:
`AGENTS.md (root) not read: outside the repository`, `CLAUDE.md (root) skipped:
AGENTS.md is used in this directory`, `lib/.github/copilot-instructions.md (nested) not
read: Copilot's file counts only at the root`. The TUI holds no table of reasons for
files; the daemon's words are the ones every client prints. An import not followed is
an entry after the file that names it, as that file wrote it: `@docs/gone.md (root)
import not followed: missing` (`too deep`, `a cycle`, `outside the repository`, or
`outside the config directory` for the person's own file), from the code
`unfollowed[].reason` has had since Decision 798, which the protocol does not retype.

- **Still one notice line** (Decision 124), each file an entry of it. The brief asked
  for "one line per file"; the notice is the status line, and an entry per file is that
  line's unit. Not here: a view of its own for `/context`, which a long answer would
  want, since the status line is clipped at the terminal's width.
- **An older daemon.** An answer without `reason` (a pod's harness that predates 806)
  prints as it did, its aliases named as `, CLAUDE.md skipped` on the file that hid
  them. With `reason`, the aliases are entries of their own and that suffix is not
  repeated.
- **Proof:** `test/troupe/context_command_test.exs` (a line with every kind of file left
  out and every kind of import not followed, none with a bare 0; `/context` against the
  harness with an `AGENTS.md` linked outside the workspace and the alias it hid; the
  alias test now reads its reason), and the installed TUI's `/context` on a scratch
  repository, on the pull request. The two new tests failed on the chunk's tip.
