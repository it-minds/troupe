---
number: 738
title: "A profile whose workers are machines has nothing in the cluster: no `WorkerProfile` in direct mode, and a count of none on the one a repository holds"
date: 2026-09-30
status: accepted
issue: 290
paths:
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/lib/troupe/plane/reach.ex
gist: "A profile whose workers are machines has nothing in the cluster: no `WorkerProfile` in direct mode, and a count of none on the one a repository holds"
---

Issue #290. An
`ssh` profile's workers are machines somebody registers, and the worker on each dials
the plane; but `admin.profile.put`, a grant, a bundle's projection and a release all
wrote it a `WorkerProfile`, and the operator, which reads no provisioner, made a
StatefulSet of pods for it. `Provision.apply/2` now asks `in_cluster?/1`, which is
the Kubernetes provisioner and nothing else. In direct mode a profile that is not in
the cluster is written nothing, and a resource left from before (a profile that was
Kubernetes's, or one saved before this was asked) is deleted, so the row stays the
whole of what is wanted; the answer is `:not_in_cluster`. In gitops mode a repository
holds every profile as a `WorkerProfile`, so the resource is there, and the plane
writes `spec.replicas: 0` onto it rather than the scaler's count, which for such a
profile is a number of machines. Between Flux's apply and the plane's first write the
CRD's default of one replica still stands; teaching the operator the
`troupe.dev/provisioner` annotation would close that, and would make it read an
annotation it deliberately reads none of. `ReleaseImage` passes such a profile by:
whoever installs the worker on a machine installs the release. Proof: `admin_test.exs`,
`provision_test.exs`, `release_image_test.exs`.
