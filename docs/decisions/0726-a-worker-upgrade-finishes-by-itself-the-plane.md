---
number: 726
title: "A worker upgrade finishes by itself: the plane drains a pod behind once it holds no active session and records that on the profile, and the operator then deletes it"
date: 2026-09-29
status: accepted
issue: 258
paths:
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/test/e2e/upgrade_test.exs
  - apps/troupe_operator/test/support/e2e/plane.ex
  - apps/troupe_plane/lib/troupe/plane/enrolment.ex
  - apps/troupe_plane/lib/troupe/plane/fleet.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/scaler.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/upgrade.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/worker.ex
  - apps/troupe_plane/lib/troupe/plane/placement.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/priv/repo/migrations/20260929000033_worker_upgrade_pending.exs
  - apps/troupe_plane/test/troupe/plane/gitops_test.exs
  - apps/troupe_plane/test/troupe/plane/placement_test.exs
  - apps/troupe_plane/test/troupe/plane/upgrade_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
  - apps/troupe_protocol/test/troupe/worker_profile_upgrade_test.exs
  - docs/admin/profiles-and-policy.md
gist: "A worker upgrade finishes by itself: the plane drains a pod behind once it holds no active session and records that on the profile, and the…"
---

Issue #258. A worker StatefulSet rolls `OnDelete`, and since #253 `UpgradePending`
names the pods behind, but nothing replaced them. The operator cannot tell a drained
pod from a draining one, since readiness fails as a drain starts, and only the plane
knows when a pod holds nothing; the plane has no pod `delete` and gets none (#253's
option (c)). So each writes what it alone knows, where it already writes: the
operator lists the pods behind in the status it owns (`status.podsBehind`, name, uid,
revision), and the plane its finished drains in an annotation (`troupe.dev/drained`,
pod to revision), because its grant is `patch` on the resource and not on the status,
under a field manager of its own so its profile writes do not remove it. The plane,
on the scaler's tick, drains the highest-ordinal pod behind that holds no active
session, only while no other pod behind is draining, and records a pod once it is
draining and a count taken on a later tick finds it empty. The operator deletes a pod
that is behind, recorded at the revision it still runs, and not Ready, one at a time,
highest ordinal first, and never while one is terminating or missing; not Ready is
what keeps a pod that restarted after its record, and may have been given a session,
from being deleted. The operator's list carries each pod's uid, and the plane keeps a
worker's uid from its enrolment token's `pod-uid` claim, because a pod's replacement
has the same name and can enrol before the next pass: drained by name, it would be a
current pod drained for good. Placement puts a new session on a current pod while one
has room (`workers.upgrade_pending`), so a busy pod's sessions go dormant in their own
time. A profile with one pod gives it new sessions until every one is dormant, then is
without a pod while the replacement starts. This is the "removes a drained pod" that
Decision 633 still owed, for pods behind only: a drained current pod still waits for
a person. What it costs: an idle pod's drain is started without waiting for it, and a
drain whose answer never arrived leaves the pod Ready and recorded until somebody
drains it again; a CRD without `podsBehind` drops it and the roll stays manual.
Proof: `reconciler_test.exs` (behind and drained is deleted; not drained, Ready again
or drained on another revision is kept; one at a time; current never), the plane's
`upgrade_test.exs` and `placement_test.exs`, and the cluster suite's `upgrade_test.exs`,
which rolls a one-pod profile with nobody deleting anything.
