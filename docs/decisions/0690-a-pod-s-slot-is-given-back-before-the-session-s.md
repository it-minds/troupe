---
number: 690
title: A pod's slot is given back before the session's row is marked, and a release that finds nothing to give back counts the profile again
date: 2026-09-26
status: accepted
issue: 173
paths:
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/drain.ex
  - apps/troupe_plane/lib/troupe/plane/placement.ex
gist: A pod's slot is given back before the session's row is marked, and a release that finds nothing to give back counts the profile again
---

Issue #173, found by the
fixer of #135. `Placement.release/2` finds a pod's slot by the session row's
`worker_id`, and `Sessions.dormant/2`, `read_only/1` and `unrestorable/2` all clear
that column. A pod's own `session.dormant` report, an erasure and a
`session.unrestorable` report each marked the row first. Their release found nothing,
and the placement actor went on counting a session that had left the pod. Only a
reserve about to be refused counted again, so until then the least-loaded pod was
chosen on counts that were too high.
- **The order.** The dormancy report and an erasure now release first, as
  `Drain.strand/2` already did. The control connection's orphan path calls
  `Drain.strand/2` rather than keep its own copy of it. The `unrestorable` report
  cannot release first: it is fenced on the epoch, and a release ahead of the fence
  would let a pod on a stale epoch give back a slot a newer epoch holds.
- **The recount.** A release whose session is on no pod reloads the actor's counts
  from the database, as the refusal path does. That covers the `unrestorable`
  report, and any caller that gets the order wrong again. It costs a group-by only
  on a release that found nothing: a session never placed, or one given back
  already. A second release of the same session finds nothing and recounts, so no
  slot is given back twice. The refusal path keeps its recount for sessions taken off
  their pods with no release at all, which a revoked grant's
  `Sessions.read_only_for/2` still does.
- **Proof:** `Troupe.Plane.ControlTest`: a pod's dormancy report takes a full pod
  from four to three without a recount, and the next reserve fits without one; an
  `unrestorable` report gives its slot back; a session the plane strands and the pod
  then reports dormant twice gives back one slot. `Troupe.Plane.HarnessTest`:
  erasing one of two running sessions leaves the pod counting one.
  `Troupe.Plane.PlacementTest`: a release after the row went dormant gives the slot
  back at once. All but the one about giving back once fail on the chunk's tip.
