---
number: 856
title: "A worker reaches no link-local or cloud metadata address by name or literal: with Cilium they are denied by address, except a NodeLocal DNSCache and the installation's own; without Cilium the public rule also leaves out 100.64.0.0/10"
date: 2026-10-11
status: accepted
issue: 361
paths:
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
  - docs/admin/profiles-and-policy.md
  - docs/admin/configuration.md
symbols:
  - Troupe.WorkerProfile.Reach.denied/1
gist: "With Cilium, link-local, fd00:ec2::254 and 100.100.100.200 are denied by address (but 169.254.20.10, the platform's); 100.64/10 is not public"
---

Issue #361, what #355 (758) left. 758 kept a profile from naming a loopback or link-local
address, but a worker could still reach a cloud's metadata service three ways.

- **With Cilium, a name.** A `toFQDNs` rule admits a name at whatever address its DNS
  answer carries, so a name in `allowedEgress` pointed at `169.254.169.254` reached it, and
  nothing where the name is typed can see that. The `CiliumNetworkPolicy` now has an
  `egressDeny` rule, a `toCIDRSet` of `169.254.0.0/16`, `fe80::/10` and the two metadata
  addresses below (`Reach.denied/1`). Cilium takes a deny before any allow, of this policy
  or another, so it holds whatever name leads there.
- **Two metadata addresses outside link-local.** EC2 serves IPv6 metadata at
  `fd00:ec2::254`, a unique-local address, and Alibaba Cloud at `100.100.100.200`. Both are
  now in `Reach`'s refused list as "cloud metadata" addresses, one address each, so a
  profile naming either is refused and reported as link-local is (749, 752, 758), and both
  are in the deny. The rest of `fd00::/8` is unchanged: an office network's unique-local
  address is still that one address.
- **Without Cilium, `100.64.0.0/10`.** The public rule now leaves out the shared address
  space as it does the private ranges (`Reach.excepted/0`). An endpoint there, the
  installation's or a profile's, is admitted only when given as its address, as one at a
  private address is (724, 752); only `100.100.100.200` is refused outright. Refusing the
  whole range was not chosen: hosted object stores answer at internal addresses in it, and
  so may an installation's gateway on an overlay network, which "unless an installation's
  own endpoint is there" in the issue allows. With Cilium the range needs nothing: it is
  reached only by a name or address the allowlist holds.
- **What the deny leaves out.** The installation's own OpenBao and object store given as an
  address inside a denied block are excepted from it (as `/32`, `/128`), and one that is a
  whole block takes that block out, since 758 keeps them the installation's choice and the
  deny would otherwise undo the `toCIDR` that admits them; a name of theirs is not, as
  nothing can know where it resolves. And `169.254.20.10`, where a NodeLocal DNSCache
  listens in its own manifests and most clusters that run one. No rule of Troupe's admits
  it (the DNS rules select the resolver's pods), so the except opens nothing; it keeps a
  policy an installation adds to a worker namespace for its DNS cache (724's remedy) from
  being undone by ours. A cluster whose cache listens elsewhere in `169.254.0.0/16` would
  need a setting; none is added until one asks.
- **Also the unspecified address.** `0.0.0.0` and `::` connect to the host connecting, so
  from a pod to the pod: refused as "unspecified", like loopback. Loopback and unspecified
  are not in the deny, since a pod's traffic to itself is not subject to the policy.
- The condition's reason stays `LoopbackOrLinkLocal`, which the console and anything
  watching it read; the message names the new kinds.
- **Proof:** the protocol's `reach_test.exs` (both metadata addresses in every spelling
  refused, the unspecified address, the ranges' edges including `100.100.100.201` and
  `fd00:ec2::253` admitted, the excepted list, `denied/1` with and without kept addresses)
  and the operator's `resources_test.exs` (without Cilium: the public rule's except list,
  the metadata addresses admitted by nothing, another address in `100.64.0.0/10` its own
  rule, the installation's object store there its own rule; with Cilium: the deny for a
  profile naming a name, the same deny for one naming nothing, and the installation's
  link-local and metadata addresses kept). Every new case failed on the chunk tip
  but the two that pin what stays admitted, the edges and the object store in
  `100.64.0.0/10`. Not checked against a live Cilium: the rule's shape is Cilium's
  documented `egressDeny`/`toCIDRSet` with `except`.
