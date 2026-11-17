---
number: 994
title: "A pod the operator removed is forgotten: a pod row whose substrate no longer runs it (an ordinal at or above the profile's count, a host no longer registered, a profile the plane no longer has) is listed gone, since it was last heard, once it is quiet past its lease, and the sweep drops the row once it is quiet past the drain deadline and holds no active session; a gone pod offers no action and is nowhere a drained pod's sessions could go"
date: 2026-11-15
status: accepted
issue: 883
paths:
  - apps/troupe_plane/lib/troupe/plane/fleet.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/sweeper.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - clients/gui/apps/console/src/views/Pods.tsx
  - clients/gui/apps/console/src/views/Overview.tsx
  - clients/gui/packages/client/src/admin.ts
symbols:
  - Troupe.Plane.Fleet.listed?/2
  - Troupe.Plane.Fleet.gone?/2
  - Troupe.Plane.Fleet.forget_gone/0
gist: "A pod the substrate no longer runs is gone once quiet past its lease and its row is dropped past the drain deadline with no active session; gone offers nothing"
---

Issue #883, folded into #928. A scale-down retires a pod (`Fleet.retire/1`, Decision 731),
and once the count is down past it `Fleet.retired/2` cleared `retiring` and kept the row:
"their rows stay, as a removed pod's always have". So the row kept `draining: true`,
`healthy: false` and a heartbeat weeks old for good, and `admin.profiles.list` and
`profiles.list` listed it. The console's Pods page and Overview read it as a pod stuck
mid-drain, with no action, and the Overview counted it among the profile's pods.

## What the plane decides

**Listed is the substrate's word, not health** (`Fleet.listed?/2`). For a profile the
cluster makes, a pod is listed while its ordinal is below the profile's `replicas`, the
count the plane writes to `spec.replicas` and the operator's StatefulSet runs; for a
registered host, while a host of that name is registered for the profile; a pod of a
profile the plane no longer has is listed nowhere. A pod that is listed and silent is
broken, or starting, and stays the administrator's to look at.

**Gone, then forgotten.** A pod that is not listed and has not been heard from for longer
than its lease is `gone` (`Fleet.gone?/2`), and `admin.profiles.list` says so on its row
(`gone: true`, with `last_seen_at` as before). The sweeper's third pass, after marking
pods unhealthy and rescuing what lost pods held, drops each row that is not listed, has
been quiet for longer than the drain deadline (`drain_timeout_seconds`, five minutes by
default, which `Fleet.drain_deadline_ms/0` now reads for the drain too) and holds no
active session (`Fleet.forget_gone/0`). The delete asks the heartbeat again, so a pod
that enrolled between the read and the write keeps its row; a pod that comes back at the
name later enrols afresh, as it always could. Sessions' `worker_id` is `nilify_all`, and a
row holding an active session is never dropped, so nothing the rescue still has to reach
is lost from under it.

**Why the drain deadline.** It is the longest the plane waits on a pod's running turns,
and the one number already in the deployment that says how long a pod may be in the
middle of leaving. A row dropped sooner could be one a drain is still waiting on; a row
kept longer is only noise. One sweep, on the timer that already counts "last heard": no
new process, no new column, no migration.

**Not chosen: asking the operator for its pods.** The plane has the count it wrote and the
hosts it registered; asking the API server every sweep would answer "what exists" at a
round trip each time, on every replica, for the one fact the plane already holds. **Not
chosen: dropping at once when the count comes down.** The pod is still sealing and
reporting then, and its row is what `Drain` reads; a gone row for a few minutes is the
honest state.

## What the console shows

A gone pod's row reads **gone** and when it was last heard, in muted grey, with no Drain;
the region's count (`ux · 1 of 1 pod`) counts the pods still run. A drain's preview counts
as somewhere the sessions could go only a pod of the profile that is healthy, not draining
and not gone, whatever the gone row's other flags last said. The Overview leaves gone pods
out of the fleet's count, of each profile's state and of "Needs attention": a removed pod
is nobody's to look at, and a profile short of a pod is still said to be short. The fake
plane seeds one gone pod (`troupe-w-ux-1`).

**Left:** `profiles.list`'s `pods` (the desktop's and the terminal's) carries no `gone`;
its rows go with the sweep like the console's, and neither client lists a profile's pods
by state today.

## Proof

- `apps/troupe_plane/test/troupe/plane/fleet_test.exs`, "a pod the operator removed": gone
  once quiet past its lease and not before, a pod still run never gone; forgotten by the
  sweep only past the drain deadline, the pod still run kept however quiet, a second sweep
  forgetting nothing; kept while it holds an active session; a pod enrolling at the
  ordinal again is a new row, not draining; a pod of a profile the plane no longer has
  forgotten too; `admin.profiles.list` saying `gone` on the removed pod's row alone. Each
  failed on the chunk's tip, where none of the three functions existed.
- `clients/gui/apps/console/test/operate.test.tsx`: the gone row reads "gone" and its time,
  not "draining", offers no Drain, and a drain of the profile's other pod says no pod can
  take its sessions even with the gone row's flags left healthy; the region counts
  `1 of 1 pod`. Both failed on the tip.
