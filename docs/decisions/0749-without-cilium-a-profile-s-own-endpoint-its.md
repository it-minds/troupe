---
number: 749
title: Without Cilium, a profile's own endpoint its workers cannot reach is refused where it is set up, and reported on the profile where nothing could refuse it
date: 2026-10-01
status: accepted
issue: 268
paths:
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/reach.ex
  - apps/troupe_plane/test/troupe/plane/reach_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
  - docs/admin/profiles-and-policy.md
gist: Without Cilium, a profile's own endpoint its workers cannot reach is refused where it is set up, and reported on the profile where nothing could…
---

Issue #268, its
smallest option; admitting such an endpoint without Cilium stays open there. Without
Cilium a worker's NetworkPolicy reaches outside the cluster through public IPv4
addresses on 443 and 80, and a `*.svc` host through its namespace; 724 added the
installation's own OpenBao and object store and nothing of a profile's. So an LLM
gateway on 8443, or an MCP server at an address on the office network, was saved,
applied and reconciled without a word, and a session found out at its first call.
`Troupe.WorkerProfile.Reach` now says, a sentence each, which of a profile's LLM
endpoint, MCP servers and `egress.fqdns` entries such a worker does not reach: a port
other than 443 and 80 in the URL (or the entry), or a host that is an address in a
range the public rule leaves out, loopback, or IPv6, which the rule has no block for.
The public rule's excepted ranges are read from it, so the two cannot drift. A name on
443 or 80 is taken at its word: a NetworkPolicy cannot name a host and what a name
resolves to is not known where it is typed, so one that resolves to a private address
is still not reached and still not said. The git hosts are not checked, as #268 does
not name them. In direct mode `admin.profile.put`, and so the
profile editor, refuses a profile whose workers are pods (`invalid_params`, the
sentences as `unreachable`, and with why and what to do as `reason`, which the editor
shows), counting the servers its channel's bundle hands its pods, and publishing a
bundle naming such a server to a channel a profile whose workers are pods follows is
refused (`invalid_bundle`, naming the profiles). A profile whose workers are machines
has no NetworkPolicy and is not checked (738). The operator reports it in either mode
as `EndpointUnreachable` (`True`, `NoCilium`, the same sentences), beside `Ready` as
`SecretMissing` is, since the profile reconciled; it is how a profile a repository
holds, applied where nothing could refuse it, reads as broken on the Workers page.
What to do is in the message: Cilium, a public address on 443 or 80, or for an
endpoint in the cluster its Service's name. With Cilium nothing is refused and the
condition is `False`. The plane learns which from the chart, which now gives it
`operator.ciliumAvailable` as `TROUPE_CILIUM_AVAILABLE`, as it gives the operator: that
setting decides which rules the operator writes, so it, and not the cluster's CNI, is
what a pod will reach. The operator's `EgressByHostname` condition says the same, but
only of a profile it has reconciled, which the one being written is not. A plane told
nothing, run without the chart, refuses nothing, and the operator still reports. Not
chosen: admitting a profile's endpoint on its port as 724 admits the platform's,
which would open that port to every public address for one profile's gateway; and
CIDRs a profile names, which needs a field and a policy for it. A NetworkPolicy an
installation adds to the worker namespace, 724's remedy for the platform's endpoints,
does not get a profile past the refusal. (752 admits the first after all, and what is
refused and reported is now an endpoint at a loopback or link-local address; 758
refuses that with Cilium too, and the plane is no longer told about Cilium.) Proof: `reach_test.exs` in the protocol (the
sentences: ports, each range, IPv6, `*.svc`, names, entries) and in the plane (the
refusal and its message, a name on 443 and a Service saved, machines, a channel's
server, with Cilium, a plane told nothing, the bundle, the editor, the Workers page),
and `reconciler_test.exs` (the condition without Cilium, with it, and reachable); the
plane's refusals and the operator's three cases failed on the chunk tip.
