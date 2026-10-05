---
number: 57
title: "`/cancel [n]` stops a branch *and* removes it: the Node is stopped, the Troupe-managed worktree it was working in is discarded, and the window is dismissed — and every window command takes the number on the tile (`/cancel 3`) as well as a path"
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe.ex
gist: "`/cancel [n]` stops a branch *and* removes it: the Node is stopped, the Troupe-managed worktree it was working in is discarded, and the window is…"
---

Stopping a branch and clearing it away were two commands (`/cancel` then `/dismiss`, plus `/discard` for the worktree) that nobody wants separately when the answer is "not this, forget it", and the path had to be typed from memory while the number was already on the tile and on the digit keys. `Dispatcher.cancel/2` is the one operation: on a resting window it removes immediately; on a running one it sends `:cancel` and removes the window when the branch comes to rest, so nothing is writing the worktree that is about to be discarded. The deferral is log-backed rather than Dispatcher state — the agent's existing `cancelled` event is now folded into the ledger as a flag, so a Dispatcher that restarts mid-cancel still finishes the removal, and no new event type was needed. A worktree the user checked out themselves is left alone (Decision 39), as is one already merged or discarded. `Troupe.cancel/2` keeps its spec meaning (send `:cancel` to one agent, window stays, which is what the property test and the cancellation acceptance test exercise); the combined operation is `Troupe.cancel_branch/2`, and `x` in a window is the combined one, since a window you stopped that way is one you are done with.
