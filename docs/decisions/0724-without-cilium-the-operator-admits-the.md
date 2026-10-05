---
number: 724
title: "Without Cilium, the operator admits the installation's own OpenBao and object store outside the cluster on the port they name: an address as that one address, a name on another port as the public rule's addresses on that port"
date: 2026-09-29
status: accepted
issue: 257
paths:
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
gist: "Without Cilium, the operator admits the installation's own OpenBao and object store outside the cluster on the port they name: an address as that…"
---

Issue #257, the half of
#249 that Decisions 721 and 723 left. Without Cilium the worker NetworkPolicy reaches
outside the cluster through one rule, public addresses on 443 and 80, so an object
store on 9000, or an OpenBao at a private address, was admitted by nothing and no
session activated. For `bao.address` and `objectStore.endpoint` that are not `*.svc`
hosts, `Resources.platform_rules/1` now adds a rule on the endpoint's own port: an IP
address, private or public, as an `ipBlock` of that one address (`/32`, `/128`), and
a name on a port other than 443 and 80 as the public rule's ranges on that port. The
public rule itself stays 443 and 80: opening it to the private ranges or to more ports
would widen it for every destination, to admit two that the installation chose. The
cost is that a name on 9000 opens 9000 to every public address, which is as much as a
NetworkPolicy can say about a name. About a name that resolves to a private address it
can say nothing, and nothing here tries: such an endpoint is given as its address, or
admitted by a NetworkPolicy the installation adds to the worker namespace (policies
add up, and the operator prunes only what carries its label), or Cilium is used. With
Cilium nothing changes. Proof: `resources_test.exs` (a name on another port, a name on
443 and 80, a private and a public address, `*.svc` endpoints, and the Cilium path).
