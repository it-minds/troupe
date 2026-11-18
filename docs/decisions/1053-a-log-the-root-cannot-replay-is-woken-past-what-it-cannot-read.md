---
number: 1053
title: A dormant session whose root cannot replay its log is woken past each event the replay raises on, by whoever may send it input, with an appended log_repaired and never a rewrite; the failure is said once, and the clients offer the wake where the refusal is shown
date: 2026-11-18
status: accepted
issue: 1053
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/session/log.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/packages/client/src/transcript.ts
symbols:
  - Troupe.repair/2
gist: "session.repair skips each event the root's replay raises on, up to the head, via an appended log_repaired (seq kept, chain whole); control scope; said once; clients offer it"
---

D48 and D135. A log the root's replay raised on could not be woken: every activating command
failed its start again and wrote another `agent_failed`, and nothing let a person past it.

- **Skip, with the log kept.** `session.repair` (`Troupe.repair/2`) wakes the session with the
  root folding tolerantly: each of its events up to the log's head *now* that its fold raises
  on is skipped, and `log_repaired {event, at, by}` appended under the root for it. Every
  replay from then on drops the events a `log_repaired` names; a later event is folded as it
  is, so a restart never skips what nobody was asked about. The event stays, and the chain
  verifies. A raise outside the fold (the turn taken up) is not this: that turn is not taken
  up again on a wake (Decision 727), so such a session already wakes.
- **Who.** Whoever may send it input: `control`, as `input.send` is. Not a pod: there the
  plane wakes a session, and `session.repair` answers `unavailable` with that sentence.
- **What the person is told.** An activating command's `unavailable` carries what the root
  raised and `repairable: true`. The desktop's composer gives way to "Wake it anyway", the
  TUI's line under the screen says "Wake it anyway? [w]", and a headless run that could not
  send names `troupe resume ID --repair`. Each sends the message once woken. The transcript
  shows "An event from <when> could not be read and was skipped", where it was in the desktop
  app and where the wake was in the terminal, which draws lines in arrival order.
- **Said once.** A root whose last word is already the same `agent_failed` is not made to say
  it again on each failed wake. Which agents have started under a tree is kept in a table the
  session's supervisor owns, so a `Log` the tree restarts does not count the root's next start
  as its first (cold), which wrote `agent_failed` one start early and dropped an interrupted
  turn as if the whole session had come back.

Not chosen: rewriting or deleting the event (the chain would break, and an audit would lose
it); starting fresh with the log kept (everything after the event is lost too); recording the
failing `seq` at the crash (a log written before this has none; the tolerant fold finds it).

Undone, a session whose log its agent cannot read is stuck dormant again, with an
`agent_failed` for every try.
