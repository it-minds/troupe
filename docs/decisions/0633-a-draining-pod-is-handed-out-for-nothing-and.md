---
number: 633
title: A draining pod is handed out for nothing, and whether it is draining is the pod's own fact
date: 2026-09-19
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/enrolment.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/scale_down.ex
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
gist: A draining pod is handed out for nothing, and whether it is draining is the pod's own fact
---

A draining pod's readiness probe answers 503, so its Service drops it,
and the plane must not send anybody there either: placement and the reader both
skip a draining pod, and `profiles.list` lists one (a person should see it) and
counts it for nothing — no capacity, not a healthy pod. The worker sends `draining`
on `enrol` and `heartbeat`. A heartbeat may only raise the flag, because the plane
raises it first when it orders a drain and a heartbeat from a moment before must
not undo that; enrolment takes it as given, because the one honest way the flag
comes down is a pod that restarted and is therefore not draining. Still owed:
something that *removes or restarts* a drained pod nobody scaled away, and an
`undrain` an admin can press.
