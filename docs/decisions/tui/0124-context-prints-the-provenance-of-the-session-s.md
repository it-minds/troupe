---
number: 124
title: "`/context` prints the provenance of the session's prompt on the notice line, as the daemon's `context.get` answers it, and holds no reading of its own"
date: 2026-09-27
status: accepted
issue: 123
paths:
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/instructions.ex
  - clients/tui/test/troupe/context_command_test.exs
gist: "`/context` prints the provenance of the session's prompt on the notice line, as the daemon's `context.get` answers it, and holds no reading of its own"
---

Issue
#123's first slice (root Decision 706). A repository's `AGENTS.md` now reaches
every prompt, with the person's own file before it, one per directory down to the
workspace after it and the brief last; the question that follows is "which files,
and did mine get in", and the TUI answers it the way `/memory` answers for the
brief: one line, `context: 1,234 of 16,000 chars · AGENTS.md (root) 800, CLAUDE.md
skipped · app/AGENTS.md (nested) 434 · .troupe/memory.md (brief) absent`, with
what the budget cut or left out said where it happened. Paths under the workspace
are shown from it, the person's own whole. `Troupe.Client.instructions/1` is the
call, `Worker.rpc` with `context.get` behind it, on a remote session too — the
pod's checkout has instruction files of its own and the method is a session's. The
TUI reads no file itself, so what it prints is what the daemon will read at the
next turn, and the command is one entry in the harness's table, held equal to the
TUI's built-ins by the palette test. Proof: `test/troupe/context_command_test.exs`
(the line for a workspace with an alias hidden, the notice from `/context` typed,
and the line's shape for a cut, a left-out file and the brief), and `/context` in
the installed TUI on a scratch repository, on the pull request.
