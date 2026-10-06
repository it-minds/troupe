---
number: 637
title: A projection must subscribe before it replays, and de-duplicate afterwards
date: 2026-09-19
status: accepted
paths:
  - apps/troupe_core/lib/troupe/session/summary.ex
gist: A projection must subscribe before it replays, and de-duplicate afterwards
---

Subscribing first and then folding the log folds an event that is already written
*and* sitting in the mailbox twice, once from each; `Session.Summary` did, and a
session's cost came out at exactly double. The replay remembers how far it got, and
a live event at or below that is dropped. An ephemeral event has no sequence, is in
no log, and so can never be a repeat. The window is a projection starting while a
turn is in flight, which is an ordinary restart, and what it corrupts is the number
the plane bills from.
