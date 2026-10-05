---
number: 721
title: With Cilium, the operator admits the installation's own OpenBao and object store by name when they are outside the cluster; a pod that cannot reach its object store says `object_store_unreachable`
date: 2026-09-28
status: accepted
issue: 249
paths:
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/test/troupe/worker/object_store_unreachable_test.exs
  - apps/troupe_worker/test/troupe/worker/plane_link_test.exs
gist: With Cilium, the operator admits the installation's own OpenBao and object store by name when they are outside the cluster
---

Issue #249. Since 0.5.0-beta.1 the worker
NetworkPolicy has no public rule where Cilium is, only a `.svc` OpenBao or object
store had a rule of its own (`in_cluster_rules/2`), and the `CiliumNetworkPolicy`
named the profile's hosts alone (`WorkerProfile.egress_destinations/1`). So an
installation whose object store was a hosted S3 service activated no session: every
restore waited out a connect timeout, and the plane relayed `timeout`. The hosts of
`bao.address` and `objectStore.endpoint` that are not in the cluster now go into the
`toFQDNs` rule beside the profile's (`Resources.platform_hosts/1`), and not into the
profile's allowlist: they are the platform's, set by whoever installed it, and the
allowlist is the profile's own destinations, which the plane shows and admission
checks against `allowedEgress`. Asking for them in every profile's `egress.fqdns`
would make each profile name, and each policy allow, a host no profile chose. On the
worker, a transport error from the object store during a restore is
`{:object_store_unreachable, endpoint, reason}` (`Restore.unreachable/2`), answered to
the plane as `unavailable` with that reason and the endpoint. It is not a
`session.unrestorable` (Decision 661): the session is intact and the plane retries.
A pod also lists the bucket once at each enrolment and logs when it cannot
(`Restore.check_reachable/1`, `Link.info/1`); a log line rather than a readiness
condition, because failing readiness over a storage outage would take the pod's
attached sessions off its Ingress as well. Proof: `resources_test.exs` (external
endpoints with and without a port, in-cluster ones, a host named twice),
`object_store_unreachable_test.exs`, `plane_link_test.exs`; and the cluster suite's
`egress_test.exs`, which dials the pod's own `TROUPE_OBJECT_ENDPOINT` and
`TROUPE_BAO_ADDR` and activates a session that seals, where it runs with Cilium.
