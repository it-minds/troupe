---
number: 752
title: "Without Cilium, a profile's own endpoints are admitted as the installation's are: a name on another port as the public rule's addresses on that port, an address as that one address on its port. One at a loopback or link-local address is admitted by nothing, and is what is still refused"
date: 2026-10-02
status: accepted
issue: 268
paths:
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_plane/lib/troupe/plane/reach.ex
  - apps/troupe_plane/test/troupe/plane/reach_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
  - docs/admin/profiles-and-policy.md
gist: "Without Cilium, a profile's own endpoints are admitted as the installation's are: a name on another port as the public rule's addresses on that…"
---

Issue #268, its second part, as decided
there; 749 did not choose this. 749 refused an LLM gateway on 8443, or an MCP server
on the office network, where the profile was set up, so an installation without
Cilium that ran its gateway in-house could not use it.
- **What is admitted.** The worker NetworkPolicy gives each of a profile's endpoints
  the public rule does not reach a rule of its own, as 724 does OpenBao and the object
  store: the LLM endpoint, each MCP server (its own, and its channel's bundle's
  through the `mcpServers` the plane projects) and each `egress.fqdns` entry, whose
  port is written `host:port`. An entry with none is reached where a name is, on 443
  and 80, an address as itself on those. An IPv6 address, which 749 refused because
  the public rule has no v6 block, is its `/128`. A public address on 443 gets its
  own rule too, as 724's do; a name on 443 and 80 needs nothing and is unchanged. No
  CRD change.
- **The cost is 724's.** A name on 8443 opens 8443 to every public address for that
  profile's workers, which is as much as a NetworkPolicy can say about a name. A name
  that resolves to a private address is still not reached and still not said, since
  what it resolves to is not known where it is typed; the docs say to give it as its
  address or use Cilium.
- **Loopback and link-local stay refused,** `127.0.0.0/8`, `::1`, `169.254.0.0/16`
  and `fe80::/10`, and a v4 address in v6 spelling (`::ffff:169.254.169.254`) is the
  v4 address it names, where the connection goes. From a pod, loopback is the pod
  itself, and link-local is the node's, where a cloud's metadata service answers: a
  rule would open that to the pod for one profile's endpoint. These are what
  `admin.profile.put`, the editor, a bundle's publish and `EndpointUnreachable` name
  now, and the message says why and to give the endpoint as a pod reaches it.
- **One judgement.** `Troupe.WorkerProfile.Reach` judges each endpoint once, into the
  rules that admit it (`admitted/1`, through `admission/2`, which the operator also
  uses for the platform's endpoints) or the sentence that refuses it
  (`unreachable/1`), and the public rule's ports and ranges are read from it. So the
  NetworkPolicy, the refusal and the condition cannot disagree about an endpoint.
- The git hosts and an MCP identity's token endpoint are still not judged, as #268
  does not name them. With Cilium nothing changes.
- **Proof:** the protocol's `reach_test.exs` (admissions and refusals: ports, both
  families, the ranges' edges, the v6 spelling, entries with and without a port, the
  platform's), the operator's `resources_test.exs` (a name on 8443, private and public
  addresses in both families, entries, loopback and link-local admitted by nothing, a
  port the platform shares, the Cilium path) and `reconciler_test.exs` (the condition
  reachable for the gateway and the server, beside their rules; named for loopback and
  link-local), and the plane's `reach_test.exs` (saved, refused, a channel's server,
  the bundle, the editor, the Workers page). The operator's NetworkPolicy and
  condition cases and the plane's saves failed on the chunk tip.
