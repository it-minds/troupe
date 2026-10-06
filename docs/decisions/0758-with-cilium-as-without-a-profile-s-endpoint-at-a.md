---
number: 758
title: With Cilium as without, a profile's endpoint at a loopback or link-local address is admitted by no rule and refused where it is set up, so the plane no longer needs to know which
date: 2026-10-03
status: accepted
issue: 355
paths:
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - apps/troupe_plane/lib/troupe/plane/reach.ex
  - apps/troupe_plane/test/troupe/plane/reach_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
  - docs/admin/profiles-and-policy.md
gist: With Cilium as without, a profile's endpoint at a loopback or link-local address is admitted by no rule and refused where it is set up, so the…
---

Issue #355, the first part of defect D54. With Cilium the plane refused
nothing (749), and the `CiliumNetworkPolicy` writes a host given as an address as a
`toCIDR` of that one address (723). So a profile naming `http://169.254.169.254/` got
a rule to the node's metadata service wherever the TroupePolicy's `allowedEgress`
named the address, and that list was all that stood between a profile and it.
- **No rule in either mode.** The `CiliumNetworkPolicy` now leaves out every host of
  the profile's that `Troupe.WorkerProfile.Reach.refused?/1` names: loopback
  (`127.0.0.0/8`, `::1`) or link-local (`169.254.0.0/16`, `fe80::/10`), a v4 address in
  v6 spelling as the address it names, the one judgement 752 made for the
  NetworkPolicy. Every host means the git hosts and an MCP identity's token endpoint
  too, though only the LLM endpoint, the MCP servers and `egress.fqdns` are judged and
  named, as before. The installation's own OpenBao and object store are its choice and
  stay as they are. A profile applied in `gitops` mode, which nothing refused, gets no
  such rule either.
- **Refused and reported in both.** `admin.profile.put`, the editor and a bundle's
  publish refuse such an endpoint whatever the plane was told, and
  `EndpointUnreachable` is `True` in both modes, with the reason
  `LoopbackOrLinkLocal` where it was `NoCilium`; `False` stays `Reachable`, or
  `Cilium`. The message names both policies.
- **The plane is not told about Cilium.** 749 gave it `operator.ciliumAvailable` as
  `TROUPE_CILIUM_AVAILABLE` to know what the operator would admit, and a plane told
  nothing refused nothing for want of knowing. What it refuses no longer depends on
  the mode, so the chart no longer gives it the value, the plane no longer reads it,
  and a plane run without the chart refuses what one with it does. Undoes that part
  of 749.
- Public and private addresses and in-cluster Services are unchanged in both modes. A
  name is still taken at its word (749): with Cilium, a name in `allowedEgress` whose
  DNS answer is such an address is admitted by the `toFQDNs` rule, which cannot be
  seen where the name is typed.
- **Proof:** the protocol's `reach_test.exs` (`refused?/1` over both families, the v6
  spelling and the ranges' edges; the message), the operator's `resources_test.exs`
  (with Cilium, every spelling and every kind of profile host left out of `toCIDR`,
  a public and a private address kept) and `reconciler_test.exs` (with Cilium, the
  condition naming the gateway on loopback and the server at the metadata address,
  and no `toCIDR`, then the same message without; reachable endpoints with Cilium
  stay `Cilium`), and the plane's `reach_test.exs` (the metadata address refused
  whatever the plane was told, a public address and a Service saved, the bundle
  refused with Cilium). The operator's two and the plane's two failed on the chunk
  tip.
