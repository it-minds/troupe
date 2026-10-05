---
number: 707
title: A session somebody is reading is never put to sleep, a call to a client's own tool outlives the connection that was serving it for a grace, and a session's row says what happened while nobody was reading it
date: 2026-09-27
status: accepted
issue: 119
paths:
  - apps/troupe_core/lib/troupe/events.ex
  - apps/troupe_core/lib/troupe/session/client_tools.ex
gist: A session somebody is reading is never put to sleep, a call to a client's own tool outlives the connection that was serving it for a grace, and a…
---

Issue #119, the daemon's last three
parts after 140's sleeping. What was there: a subscribed client kept its session on
a thirty-minute clock and then had it stopped underneath them; a client that dropped
mid-call had the call failed at once with a bare `disconnected`, its tool gone; and
a person who came back had no way to tell, short of a replay, that a turn had ended
or a question been asked while they were gone.
- **Read means subscribed by name.** `Troupe.Events.attach/1` is registered by the
  gateway for a subscription that names the session, `session:<id>` or
  `presence:<id>`, and taken back when the last one on that connection goes, so
  "somebody is reading this" is narrower than "somebody follows
  it" (`watched?/1`): a `fleet` subscriber and a worker's uplink follow every session
  and read none. The index skips an attached session on both clocks and restarts
  them from the sweep after the reader leaves; the watched clock (30 min) still
  covers the followers, and nothing changed for a pod, whose uplink is a follower
  and whose manager keeps its own dormancy.
- **The call is parked in the registry, not the connection.** The connection still
  answers its in-flight `tool.invoke`s with `disconnected` on the way out — it is the
  only process that can unblock the task — and the task then asks `ClientTools` to
  wait for the tool by name (`await/4`), for the grace or for what is left of the
  call's own timeout, whichever is shorter, so the whole thing stays inside that
  timeout and a dropped laptop is never a hung turn. A client that registers the
  tool again, through a fresh consent as it always must, is asked the same call: same
  id, same arguments, over its own connection. Nobody inside the grace, and the call
  fails once, naming the tool and saying its client left. `TROUPE_CLIENT_TOOL_GRACE_SECONDS`
  (60; `0` fails at once) sits on the ladder in the daemon's README with the other
  clocks, which the three modules that keep them now point to instead of restating.
- **`unseen` is a mark beside the log, not an event in it.** `seen` holds the head
  `seq` as of the last moment a client was attached, written on attach and on
  detach; the row counts the root agent's `turn_ended`s and its distinct
  `approval_requested`s and `question_asked`s after it, with `since`, and is empty
  while a client is attached or when no mark exists — which is also what keeps every
  session from before this from lighting up at once. A reader's progress is not
  something the session did, reading a dormant session must not write to a log it
  has not opened, and a mark in the log would reach every other subscriber as an
  event about somebody else's screen. Cleared by a subscription, never by a listing,
  so an inbox refreshes without losing its markers. The row is the contract for the
  desktop app's notification and marker; the events keep their shape.
