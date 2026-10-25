---
number: 944
title: "A drain waits for the pod while the pod says how far it has got, up to a ceiling the audit names, and the operator acts on the plane's record of a finished drain at once; an egress entry's port means the same with Cilium as without, and an MCP identity's token endpoint is admitted and judged as a server is"
date: 2026-10-25
status: accepted
issue: 765
paths:
  - apps/troupe_plane/lib/troupe/plane/drain.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/reach.ex
  - apps/troupe_plane/test/troupe/plane/drain_test.exs
  - apps/troupe_plane/test/troupe/plane/reach_test.exs
  - apps/troupe_plane/test/support/fake_pod.ex
  - apps/troupe_worker/lib/troupe/worker/drain.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
  - apps/troupe_worker/test/troupe/worker/drain_test.exs
  - apps/troupe_operator/lib/troupe/operator/skip_observed.ex
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/watch.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_operator/test/support/fake_cluster.ex
  - apps/troupe_operator/test/support/e2e/plane.ex
  - apps/troupe_operator/test/e2e/upgrade_test.exs
  - apps/troupe_operator/test/e2e/egress_test.exs
  - apps/troupe_protocol/lib/troupe/policy.ex
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/policy_test.exs
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
  - charts/troupe/crds/workerprofile.yaml
  - charts/troupe/templates/admission-policy.yaml
  - dev/kind/values.yaml
  - docs/admin/monitoring.md
  - docs/admin/profiles-and-policy.md
  - docs/admin/configuration.md
symbols:
  - Troupe.Plane.Drain.pod/2
  - Troupe.Plane.Drain.progress/2
  - Troupe.Worker.Drain.run/1
  - Troupe.Operator.SkipObserved.observed?/1
  - Troupe.WorkerProfile.drained_revision/1
  - Troupe.Policy.matches?/2
  - Troupe.Policy.host_and_port/1
  - Troupe.WorkerProfile.Reach.ntoa/1
gist: "Drain waits while pod sends drain.progress; gives up silent or at an audited ceiling; status.drainedRevision; host:port = host on that port, any CNI"
---

# A drain waits for the pod while it reports, and an egress entry means the same under every CNI

Two defects of the plane's edges, D40 and D54, for #765's spine: "a drain waits for the pod
and the operator acts at once; every egress edge a first organisation hits is closed".

## The plane waits for a pod that is still draining

`Drain.pod/2` pushed `drain` and waited the drain's timeout and 30 s for the answer. The pod
lets running turns finish, up to that timeout, and then puts its sessions to sleep one after
another, each given up to 120 s to seal and upload, so three busy sessions outlast it.
Reproduced in the plane suite with a fake pod that took eleven seconds a session and a
timeout of 300 ms: at 30.3 s the push failed, and the plane took the pod for unreachable and
marked its sessions dormant while the pod was still putting the third to sleep.

- **The pod reports.** `Troupe.Worker.Drain.run/1` takes `progress:`, told the total and the
  sessions left as the drain starts and again, with the session in hand, before each one it
  puts to sleep. The push handler sends each as a `drain.progress` notification down the
  link the push came in on. Session ids and counts only, as every other report on the link.
- **The plane listens wherever the drain is waited on.** The control connection hands each
  report to `Drain.progress/2`, which broadcasts it on the plane's PubSub under the pod's
  worker id, so the replica waiting on the drain hears it whichever replica the pod is
  attached to. The wait subscribes before it pushes.
- **How long.** The timeout and 30 s, and from each report a session's 120 s and 30 s again,
  whichever is later, up to a ceiling: the timeout, 120 s for each session the pod holds (the
  plane's count, raised once by the pod's own `total`), and 30 s. 690 s for three sessions
  at the defaults. A pod of an earlier release sends nothing and gets the timeout and 30 s,
  or 150 s if that is longer: never less than before.
- **Silence is the failure.** A pod that stops reporting before it answers, or one still
  reporting at the ceiling, is given up on as a lost pod is: its sessions are marked dormant
  at their last seal (`strand/1`), and `pod/2` answers `{:error, {:gave_up, :silent |
  :ceiling, ids}}`. The audit has `pod.drain.gave_up` by `system:drain`, naming the pod,
  the reason, the ceiling in seconds, how long the plane waited and the sessions. An
  unreachable pod is unchanged: marked so, and `{:ok, %{unreachable: true}}`.

## The operator acts on the record at once

The plane records a finished drain in the `troupe.dev/drained` annotation, which no
generation counts, and `SkipObserved` halted every event whose generation the last pass had
run: the pod was replaced at the next resync, up to 30 s later. Reproduced in the operator
suite: a profile whose annotation had just named its pod was `observed?`.

The precedent of `status.effectiveRevision` (Decision 913) is followed rather than a second
watch: each pass that applies a profile writes `status.drainedRevision`, a hash of the record
it acted on (`WorkerProfile.drained_revision/1`), and `SkipObserved` halts an event only when
the record it carries is that one. A new field in the CRD's status, so the CRDs are applied
before the upgrade as they always are; with an older CRD the field is pruned, every event
goes through, and a pass that changes nothing writes nothing. A pod still Ready when the
record lands is not replaced then, and its readiness changing is no event the operator hears,
so it waits for the resync: that order is unusual, since the plane records a drain a scaler
step after starting it, by when the pod's readiness probe has failed. The e2e times the
ordinary order and says when it saw the other.

## An egress entry's port, under every CNI

An `egress.fqdns` entry written `host:port` was compared to `allowedEgress` as the whole
string, and with Cilium became a `toFQDNs` `matchName` that carried the port and admitted
nothing; without Cilium it was the public addresses on that port. Now:

- **`Troupe.Policy.host_and_port/1`** reads a port as one to five digits after the one
  colon, or after `]:` behind a bracketed IPv6 address; anything else is the entry as
  written. **`matches?/2`** compares host and port apart: the host as before, a pattern with
  no port covering any port and one with a port that port alone. The admission rule reads
  entries the same way, written out in CEL for each side, and computes the uncovered hosts
  once (`variables.outside`) for its check and its message.
- **With Cilium** the host is the `matchName` or the `toCIDR`, with a `toPorts` of that
  port, one rule per port; an entry with no port is admitted on any port, as before.
  Without Cilium the NetworkPolicy admits the same entry on that port, as it did.
- **An MCP identity's `tokenUrl`** was egress at admission and with Cilium (Decision 747)
  but no endpoint of `Reach`'s: without Cilium a token endpoint on 8443 was admitted by no
  rule, and one at a loopback or metadata address neither refused nor named. It is an
  endpoint now (`{:token, server, url}`), admitted on its port, refused where a server is
  refused, in the plane's check at `admin.profile.put` and in the operator's
  `EndpointUnreachable`, and a `*.svc` one is its namespace on its port.
- **IPv6 in `::/96`** is printed `::2`, not `:inet.ntoa/1`'s `::0.0.0.2`, by `Reach.ntoa/1`,
  which both the NetworkPolicy's blocks and the Cilium policy's `toCIDR` use.

## Not decided here

An IP-literal endpoint inside the cluster, a pod's or a Service's address, still gets an
`ipBlock` without Cilium and a `toCIDR` with it, and what either admits depends on the CNI.
Refusing it at validation needs the cluster's pod and Service ranges, which neither the plane
nor the operator knows; an installation setting for them is a product choice left to the
maintainer (D54). The docs say to name the Service.
