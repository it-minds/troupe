---
number: 742
title: The chart keeps the namespace it makes and can be told not to make one, and a count the cluster did not take is sent again
date: 2026-10-01
status: accepted
issue: 303
paths:
  - apps/troupe_plane/test/troupe/plane/scaling_test.exs
  - charts/troupe/templates/namespace.yaml
gist: The chart keeps the namespace it makes and can be told not to make one, and a count the cluster did not take is sent again
---

Issue #303, D44 and D40 in
docs/developer/defects.md. `templates/namespace.yaml`
rendered the release's namespace as an ordinary resource, so `helm uninstall`, a
reinstall, or a GitOps controller's remediation that uninstalls deleted it with
everything else in it: an OpenBao beside the plane, the Secrets the chart expects, volume
claims, the `WorkerProfile` resources. It now carries `helm.sh/resource-policy: keep`, as
the default `TroupePolicy` already did; an upgrade puts the annotation on the live
namespace and in the release's manifest, which is what an uninstall reads.
`createNamespace` (true by default, so an upgrade changes nothing else) leaves the
namespace out where something else made it: Helm refuses to take over a namespace it did
not make, and the install guide's order, the Secrets first, makes one. Turning it off on
an install from an older chart is safe only after one upgrade with it on, because an
upgrade deletes what the chart stops rendering unless the live object says keep. Not
chosen: dropping the namespace from the chart, which would delete it at the next upgrade
of every install that has no keep yet.

In direct mode the scaler wrote the row and then the cluster, and judged the next tick by
the row, so a write the cluster refused was never sent again. On a tick that changes no
count it now reads the resource's `spec.replicas` back and sends the row's count where
they differ, the comparison gitops mode's pass already makes. Not chosen: writing the row
only after the cluster took it, which would let any other write from the row (an edit, a
grant, a release) put the old count back in between. Proof: `scaling_test.exs` ("a count
the cluster did not take") and the chart job's "The namespace outlives the chart".
