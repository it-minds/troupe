---
number: 1081
title: "A wake that finds no room waits for a place as a create does: its slice reserved, the row `pending` under the epoch the wake took, the client answered `waiting`, and the scaler's pass restores it when a pod has room; at the ceiling or on a profile the plane has no record of it goes back to sleep and is refused"
date: 2026-11-20
status: accepted
issue: 1149
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - clients/gui/packages/client/src/attach.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/tui/lib/troupe/remote/worker.ex
symbols:
  - Troupe.Plane.Harness.admit/1
  - Troupe.Plane.Sessions.pending_for/2
gist: "Wake with no room (below the ceiling, profile known): budget slice, row pending at the bumped epoch, answer = waiting_for (+profile); open/mint while pending answers waiting; scaler admit restores where epoch > 1, a pod refusal re-queues; ceiling or unknown profile -> dormant + refusal; pending ordered by last_active_at; clients show the wait"
---

Issue #1149. A wake refused for room left the row `active` on no pod. That row made the
scaler bring a pod up for a profile at none, but until the sweep (Decision 1072) marked it
dormant a minute later, the next open was handed a reader pod's endpoint in mode `activate`
for a session nothing ran. This narrows 1072: its "a wake with no room is left as it is".

- **Waits.** `start_elsewhere` refused with `at_capacity` or `no_healthy_worker`, under the
  profile's ceiling: the session's slice is reserved (Decision 498, so a team with nothing
  left is told so now and stays asleep), the row goes `pending` with no prompt, and the
  answer is a waiting create's, carrying `profile`. Everything a restore needs is on the
  row already: the epoch the wake took, terms, team, agent, `usage_seq`.
- **Again.** `session.open` in `activate` mode on a `pending` row, and `token.mint`, answer
  waiting; never a second epoch or row. A waiting create opened from a list gets the same.
- **Admitted.** `Harness.admit/1` restores a row whose epoch is past one (only a wake bumps
  it; a create's stays at one until it has run) with `session.activate` as a wake does: no
  workspace source, no prompt. A pod that refuses re-queues it, slot back, slice kept; the
  grant check, the park and `:erased` are the create's.
- **Not waited for.** At the ceiling the session goes back to sleep with the create's
  ceiling refusal; with no profile row, with the create's `unavailable`. The pods-full
  refusal of Decision 1001 ("every pod is full ... allows N") is gone with it.
- **Fair.** `pending_for` orders by `last_active_at` (when it began to wait: a create's
  creation, a wake's wake), so an old session woken now does not go before a create that
  has waited longer.
- **Clients.** `SessionAttachment` says `waiting` with the plane's reason and asks
  `token.mint` as `retry_after_ms` says; the desktop's session screen draws "Waiting for a
  free place in <profile>." in the queued colour, the new-session screen's words, and the
  command that woke it runs once it is placed. The TUI's activating command is answered
  "waiting for a free place in <profile>: ... send this again then", input waits, and it
  asks again until a note says the session is awake; the plane holds no text for a wake.

Not chosen: going dormant at once (a profile at zero would never scale up); a column
marking a wake (the epoch already says it); holding the typed text at the plane.

Undone, a wake on a full profile is `active` on no pod again until the sweep, and its next
open is handed an endpoint for a session no pod holds.
