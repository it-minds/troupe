---
number: 53
title: "A session can be closed: `Dispatcher.close/2` refuses while branches are active or managed worktrees are neither merged nor discarded, then writes a `session_closed` event and stamps `closed_at` into `meta.json`"
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/session/log.ex
gist: "A session can be closed: `Dispatcher.close/2` refuses while branches are active or managed worktrees are neither merged nor discarded, then writes…"
---

Nothing recorded when a session was over, so `troupe sessions` could not tell a finished session from an abandoned one; `finished?/1` answers the same question live (at least one branch, none active). A user-owned worktree (Decision 39) never blocks the close, because Troupe does not commit there and `/merge` already refuses it — resolving it is the user's business, not the session's. The report's `done`/`failed` counts read the window's `reason` and `message` rather than its state, so they stay correct after the window is dismissed. The event is terminal: no fold consumes it, replay is unaffected, and `Log.close_on_disk/3` writes the same pair for a session whose Log is not running (safe because a stopped session has no writer).
