---
number: 697
title: "A team's grant on a profile holds wherever one of its sessions could run or start: on the pod running it, in what that pod reports afterwards, when it is woken and when it is placed after a wait"
date: 2026-09-26
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/test/troupe/plane/grant_enforcement_test.exs
gist: "A team's grant on a profile holds wherever one of its sessions could run or start: on the pod running it, in what that pod reports afterwards, when…"
---

Decision 694 made a revoke leave the team's
sessions on the profile read-only and give back what the running ones held. These
are the places that went on without looking at the row or the grant.
- **The pod.** `Identity.revoke/2` takes each running session through
  `Drain.withdraw/1`: `Drain.park/1`, then the `session.dormant` an archive sends,
  pushed to the pod running it, which seals the session, uploads its workspace and
  deletes its own copy. The plane does not wait for it, because a pod takes as long
  as a seal and an upload take and a revoke can cover many sessions; a pod that does
  not answer is logged.
- **What the pod reports.** `Sessions.dormant/2` leaves a `read_only` or `erased`
  row as it is and answers `{:error, :parked}`. It reads the state under the row's
  lock, so a park or an erasure landing at the same moment is wholly before it or
  wholly after it. The control connection applies a dormancy report's status only to
  a row the report made dormant; the slot and the slice releases stay, and give back
  nothing twice.
- **Sessions waiting for room.** A revoke parks them as well
  (`Sessions.holding_for/2`), which gives back the slice each reserved when it was
  created, and `Sessions.read_only/1` drops the prompt kept for one.
- **Waking and placing.** `session.open` in `activate` mode, for a session that is
  not already running, and the scaler's `Harness.admit/1` check that the session's
  team exists and holds a grant on its profile (`Identity.granted?/2`). A wake is
  refused with `forbidden`. Admission checks before it reserves anything, parks the
  session and answers `:no_grant` or `:no_team`, and the scaler goes on to the next
  session, since no room was taken.
- **The pod's harness.** An activating command reaches a tree that is running on the
  pod and never brings one back: the worker's endpoint gives the gateway
  `Troupe.Worker.Sessions.running/1` in place of `Troupe.activate/1`, through the
  endpoint's new `activate` option. A session with no tree there answers `not_found`
  with `data.kind` of `session`, which a client follows to the plane (PROTOCOL.md §6,
  "A session that moves"), whatever the pod has of it on disk. A manager still
  putting its tree back is waited for. The local daemon's endpoint has no such
  option and restores as before, and `session.create` on a pod, open only to a token
  with no session (PROTOCOL.md §7), is unchanged.
- **Proof:** `Troupe.Plane.GrantEnforcementTest`: a revoke pushes `session.dormant`
  to the pod and parks a waiting session with its slice back; a wake is refused with
  the grant gone and with the team gone; admission parks instead of placing in both
  cases, and the scaler places the next session. `Troupe.Plane.ControlTest`: a pod's
  dormancy report leaves a revoked session read-only and an erased one erased.
  `Troupe.Worker.PlaneLinkTest`: a revoke stops the session on a real pod, and the
  pod's report leaves the row read-only. `Troupe.Worker.HarnessWebSocketTest`:
  activating commands for a session the pod has only on disk answer `not_found` and
  start nothing. All ten fail on the chunk's tip.
