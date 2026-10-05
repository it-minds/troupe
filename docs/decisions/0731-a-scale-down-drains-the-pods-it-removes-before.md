---
number: 731
title: A scale-down drains the pods it removes before it lowers the count, and finishes once it has started; a worker stopped by anything else drains itself
date: 2026-09-29
status: accepted
issue: 273
paths:
  - apps/troupe_plane/lib/troupe/plane/fleet.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/scale_down.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/scaler.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/worker.ex
  - apps/troupe_plane/priv/repo/migrations/20260929000034_worker_retiring.exs
  - apps/troupe_worker/lib/troupe/worker/drain.ex
  - docs/admin/profiles-and-policy.md
gist: A scale-down drains the pods it removes before it lowers the count, and finishes once it has started; a worker stopped by anything else drains itself
---

Issue #273.
The scaler wrote a lower `spec.replicas` as soon as the grace period had passed, and
the StatefulSet took the highest ordinals with what they held: a turn in flight and
the workspace since its last archive, while clients saw the session vanish until the
sweeper marked it dormant from its last seal. `Drain.scale_down/3`, which the
scaler's documentation relied on, had no caller but a test, and is gone. Now the
scaler marks the pods above the count it wants `retiring` and draining, drains them
in the background with the drain an administrator starts (`Drain.start/2`, which the
upgrade of 726 uses too), and lowers the count from the top past each retiring pod
that is draining and holds no active session on a count taken before that tick,
never past one the plane still counts a session on. A turn in flight gets the drain
timeout, the number the grace period is set from, and is then cancelled with
everything before it sealed: bounded, because a session that never rests would
otherwise keep a pod nobody needs, and no harsher than deleting the pod. Nothing
retries; the pod is asked once and each tick reads the count. A scale-down that has
started is finished even when the sessions come back, because a drained pod takes no
session until it restarts (633) and kept it would be room counted that is not there:
the count comes down past it and the next tick asks for a fresh pod. `retiring` is
what tells this drain from an administrator's, which stays a person's (633, 726)
unless its pod is above the wanted count; it is cleared when the count passes the
pod and whenever a pod is not draining. 726's `troupe.dev/drained` record is not
used: it tells the operator to replace a pod behind, and nobody but the plane is
needed to remove a pod, since it writes the count. A count that grows while a
retiring pod still drains grows past it, and that pod goes with the next scale-down
that reaches it. The worker drains on SIGTERM as well (`prep_stop/1`) for pods the
plane did not stop: turns get half its drain timeout and the rest of the grace
period is for sealing, archiving and reporting; a shorter grace period ends it as a
stop always did. The plane migrates (`workers.retiring`). Proof: the plane's
`scaling_test.exs` (drains first, a busy pod delays it, a drained pod goes, a started
scale-down finishes, an administrator's drain is left), the worker's `drain_test.exs`
(a pod stopped mid-turn puts its session to sleep and its files survive the volume),
and the cluster suite's `capacity_test.exs`.
