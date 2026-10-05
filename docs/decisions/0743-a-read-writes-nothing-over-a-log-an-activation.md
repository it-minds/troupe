---
number: 743
title: A read writes nothing over a log an activation has, and a reader whose log has gone does not answer from it
date: 2026-10-01
status: accepted
issue: 302
paths:
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
gist: A read writes nothing over a log an activation has, and a reader whose log has gone does not answer from it
---

Issue #302. Decision 732 put a reader's restore of the
log and its removal under one lock per session on the pod, and left three gaps where a
`session.read` meets a `session.activate` of the same session, which the pod's link
runs at the same time. `Reader.open` looked for a manager before it started the reader
and not again, so an activation that registered while the reader fetched the segments
had storage's copy written over its log, losing what it had logged since its last
seal. The reader now looks where it writes, under the lock (`Restore.events/3` with
`unless_active`), writes nothing if a manager holds the session's name, and the read
is answered as one of a running session. An activation looked for a log already on
the pod outside the lock, so a reader writing its log as the manager registered went
unseen and a failed activation removed it from under whoever read it; the activation
now looks under the lock, once it holds the session's name, so a reader has either
written and its log is found, or finds the name taken and writes nothing, and the log
the activation wrote is removed under the lock too. A reader whose log is no longer
the one it restored, taken over by an activation and erased when that one put the
session back to sleep, answered a later read from the history it had until its next
idle tick, with nothing on disk; asked now, it goes, giving up its name after it has
dealt with its log, and the read starts another over what storage has, once. The lock
is still the only one either side takes, and nothing done under it calls a manager or
a reader, so neither can hold it waiting for the other. Proof: the cases of a read
racing an activation in `reader_log_test.exs` and `failed_activation_test.exs`, each
failing before this change.
