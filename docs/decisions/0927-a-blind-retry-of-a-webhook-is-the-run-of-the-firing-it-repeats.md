---
number: 927
title: "A POST to a trigger's URL without an `Idempotency-Key` is the run of a firing of the same trigger and revision less than a minute before it, decided under the trigger's row lock, not the run of the clock's minute; and a repeat that finds its run still making its session waits for that session, up to five seconds, then answers `409` naming the run"
date: 2026-10-19
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/test/troupe/plane/trigger_ingress_test.exs
  - docs/admin/bundles-and-triggers.md
symbols:
  - fire_in_window
gist: "A keyless webhook retry is the run of a firing <60 s before it (trigger row lock), not the clock minute's; a repeat waits for a session still being made, then 409 naming the run"
---

# A blind retry of a webhook is the run of the firing it repeats

## Context

`POST /trigger/<id>` without an `Idempotency-Key` was keyed on the trigger, the revision
and the clock's minute (`Triggers.window_key/1`). A POST at :59 and its retry a second
later were two keys, so two runs: the second was `skipped` under the concurrency cap the
first held and answered `202` with no session. The release CI of 0.23.0 failed so in the
cluster suite ("does not double-fire when an executor retries blindly"): the first
session was made at 09:38:59 and the retry came after the minute turned. The plane's own
test of the same thing had been made to wait out the end of a minute instead
(`same_minute!`). Decision 914 moved a run by hand from the second to the minute for the
same reason; the minute only made the boundary rarer.

A second hole sat beside it. Two firings that agree on a run, by the unique key or by the
window, race: the one that loses the insert reads the winner's run between its row and
its session, and `replay/3` answered such a run with no session too.

## Decision

- **A minute from the firing, not the clock's minute.** `Triggers.fire_in_window/5` is
  what the ingress calls when the caller sends no key. It takes the trigger's row
  (`FOR UPDATE`) in a short transaction, looks for a run of the same trigger and revision
  whose key is under `<source>:<trigger id>:<revision hash>:` and that fired less than 60
  seconds before now, or after it, and repeats that run; only if there is none does it
  write a new one, keyed with the instant it fired. The session is made after the
  transaction, so nothing a create writes is hidden from the pod it is placed on.
- **The prefix is the old one.** A run keyed on a minute by the release before is found
  by the same prefix, so a retry across an upgrade is still the run it repeats.
- **A run still being made is waited for.** A repeat that finds a run with no session that
  is neither skipped nor failed polls the row every 50 ms for up to five seconds, then
  answers as for any other repeat. One still unmade after that is a `conflict` (`409` at
  the ingress) whose data names the run. This holds for every key, a caller's own
  included.
- `Triggers.window_key/1` is gone; the window is no longer a key anybody computes.

## Choices not taken

- **Keep the minute and also look in the minute before.** Two firings that race either
  side of :00 each look before the other has written, and both insert. A window needs one
  place where the two meet, and with two keys there is none but a lock.
- **An advisory lock held across the create**, so a repeat waits for the session without
  polling. Held on a pooled connection across a harness call, it outlives a crashed
  request on that connection; inside a transaction, the session row the create writes is
  invisible to the pod until commit.
- **Give the run its session id before the session exists** (`session.create` takes
  one). `session_id` on a run means a session exists today: the concurrency count, the
  retry of a failed create and the run's state all read it so.
- **Answer the overtaking repeat with `409` at once.** An executor that retried because
  the first was slow would be told to retry again, for a session a few milliseconds
  away.

## Proof

`apps/troupe_plane/test/troupe/plane/trigger_ingress_test.exs`, "the run it makes": a
retry after the first run is moved to the last tenth of a second of the minute before
(the cluster suite's failure), three blind retries racing, two racing at either side of
a minute's turn with the clock given, and a repeat that overtakes a run still making its
session, then one whose session never comes. On the code before this, the retry across
the turn, the racing retries and the overtaking repeat each got a `202` that carried no
session. `same_minute!` is gone from the old test.

A run by hand (`admin.trigger.run`) and a GitHub fix by hand still key on the minute
(Decision 914, Decision 917) and keep the boundary; they are left for their own change.
