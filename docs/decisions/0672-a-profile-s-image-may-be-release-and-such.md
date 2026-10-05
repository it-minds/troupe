---
number: 672
title: A profile's image may be `release`, and such profiles move with the platform
date: 2026-09-21
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/release_image.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/test/troupe/plane/release_image_test.exs
  - charts/troupe/values.example.yaml
  - charts/troupe/values.small.yaml
gist: A profile's image may be `release`, and such profiles move with the platform
---

A
release rolls the plane, the operator, the A2A facade and the GUI, but a worker's
image is its profile's. CI cannot move them through the admin API, because a
service principal is refused administration on purpose (`Troupe.Plane.Admin`), and
writing the custom resources behind the plane would be a change its own record
never saw. So the plane does it. The chart names this release's worker image
(`worker.image`, defaulting to the chart's appVersion) and hands it to the plane as
`TROUPE_WORKER_IMAGE`; a profile whose image is the word `release` keeps the word
in its row, and `Provision` resolves it wherever a manifest is rendered and
checked, so the policy judges the resolved image exactly as it judges a typed one.
`admin.profile.put` refuses `release` on a plane deployed without a worker image,
rather than writing a WorkerProfile with none. `Fleet.ReleaseImage` runs once as
each replica starts: every `release` profile whose resource carries another image
is written again through `Provision.apply/2`, the path an administrator's edit ends
in, audited as `profile.put` by `system:release` with the image's move as the diff.
It runs on every replica rather than as a singleton, because a `:global` singleton
can live on a replica of the release being replaced and would write the old image
back; the replica that started last has the last word. It never blocks boot, backs
off to ten minutes while the cluster or the database will not answer, and does not
give up. In GitOps mode it compares against what it last committed, not the live
resource, so a Flux that has not caught up does not cause a commit on every
restart. What it does not do: move a running pod. Worker StatefulSets roll
`OnDelete`, so the resource says `UpgradePending` until the pods are drained and
replaced — the routine-tasks page says so — and `profile.get` still reports
`release` rather than what it resolves to; the console shows the resolution.
The policy in `values.yaml`, `values.small.yaml` and `values.example.yaml` allows
the chart's own worker image, so it admits `release`. Proof:
`Troupe.Plane.ReleaseImageTest`.
