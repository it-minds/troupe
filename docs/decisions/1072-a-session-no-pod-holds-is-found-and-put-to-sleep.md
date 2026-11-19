---
number: 1072
title: "A session no pod holds is found and put to sleep: the sweep marks an `active` row on no pod dormant once it has been so for a minute, a pod's connection asks it what it holds every minute and puts to sleep what an answer does not name, and a rescue marks the row before it gives the slot back"
date: 2026-11-19
status: accepted
issue: 1141
paths:
  - apps/troupe_plane/lib/troupe/plane/fleet/sweeper.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/drain.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
symbols:
  - Troupe.Plane.Sessions.adrift/1
  - Troupe.Plane.Sessions.dormant_on/2
  - Troupe.Plane.Drain.rest/1
  - Troupe.Plane.Drain.strand/2
gist: "Sweep: active + no worker_id + unwritten 1 min -> dormant (pending untouched); connection asks session.index at enrolment and every minute, by its own pid, judging only rows placed before enrolment or 1 min before the ask; strand = dormant_on first, then a recounting release; admin rows carry pod, profiles sessions_without_pod"
---

Every rescue of a session started from its pod, so a row `active` on no pod, or on a healthy
pod that did not hold it, was counted by the scaler every tick and reached by nothing.

- **The sweep's rule.** Each pass marks dormant (`Drain.rest/1`) a session `active` with no
  `worker_id` that nothing has written for a minute (`Sessions.adrift/1`, `adrift_after_ms`):
  past the moment between a create's or a wake's row and its placement, and past the thirty
  seconds a pod is given to take one. A `pending` row has no pod by design and is left.
- **The pod's answer.** A pod's connection asks `session.index` at enrolment and then every
  minute (`index_every_ms`) while it lasts, on its own timer rather than the sweep's, which
  runs on every replica and holds no connection. It asks down itself, by its own pid, never
  by the pod's name: the reason the old comment gave against a retry, a task that outlives
  its connection and reaches whatever is registered under the name next, does not arise,
  since the ask fails with the connection. Nothing is stored; each answer is compared as it
  arrives. It judges only a session placed before the pod enrolled or a minute before the
  question (`index_grace_ms`), so one whose activation is on its way is not judged by an
  answer put together before it arrived. No answer, or an answer without `sessions`, marks
  nothing.
- **Dormant first.** `Drain.strand/2` marks the row with `Sessions.dormant_on/2`, one
  statement setting the state and clearing the pod under the row's lock, and only while the
  row is still `active` on that pod (else `:moved`); the slot is given back after, by a
  release that counts the profile again. This reverses Decision 690's order for this path:
  released first, a rescue that stopped between its writes, or a `dormant` that answered an
  error, left the row `active` on no pod. Not a transaction: the release runs in the
  placement actor's process. Any other error leaves the row placed and is logged.
- **A wake with no room** is left as it is: its row stays `active` on no pod until the sweep
  marks it, and the scaler brings a pod up for it meanwhile, which is how a wake on a profile
  at no pods gets one. Put back to sleep at once, such a profile would never scale up.
- **Seen.** `admin.sessions.list` rows carry `pod`; a profile's summary carries
  `sessions_without_pod` and a sentence while the sweep has some to mark.

Not chosen: leaving rows with no pod out of `Sessions.demand_for/1` (a create's and a wake's
row is `active` before its placement, and `within_ceiling?/1` counts it); storing the answer
on the worker row for the sweep to compare (a migration for what the connection already has
in hand); marking on a pod's silence.

Undone, such a session stays `active` for good and keeps a pod of its profile up.
