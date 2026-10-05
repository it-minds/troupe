---
number: 646
title: A branch is a session with a `parent`, and nothing more
date: 2026-09-20
status: accepted
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tools/read_branch.ex
  - apps/troupe_core/test/troupe/tools/read_branch_test.exs
  - apps/troupe_gateway/test/troupe/gateway/branches_test.exs
gist: A branch is a session with a `parent`, and nothing more
---

Not several root
agents in one session, each a window, as the TUI's own harness had: Martin chose a
session of its own for the daemon, which the core already handled — the second
session in a busy workspace gets its own worktree — and the client groups them. So
`session.create` takes `parent`, the daemon refuses an id it does not know,
`session_created` carries it, the index folds it back from the log for a dormant
session, and `session.list` filters on it. Nothing about how the session runs
changes: no shared log, no window ledger, no locks between branches, because their
worktrees keep them apart. The one thing an agent needs from a branch is what it
finished with, so `read_branch` lists a session's family — its branches, or its
siblings and the session they came from — and reads a finished one's prompt,
summary and task list off its log, never its transcript. It reads only the family:
a branch is not a way to open any log on the machine by guessing an id. `branches:
true` at `initialize` says a server does all of this; a worker says false, since a
pod has one session and no worktrees.
