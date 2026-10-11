---
number: 866
title: "A trigger's notify_url is refused at every address a worker's endpoint is, read from Reach's one list, and anywhere in 100.64.0.0/10, by literal or by a name that resolves there"
date: 2026-10-11
status: accepted
issue: 588
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers/notify.ex
  - apps/troupe_plane/test/troupe/plane/trigger_notify_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - docs/admin/bundles-and-triggers.md
symbols:
  - Troupe.WorkerProfile.Reach.refusal/1
gist: "notify_url is refused at Reach.refusal/1's addresses (loopback, unspecified, link-local, cloud metadata) and all of 100.64.0.0/10, by literal or name"
---

Issue #588, the plane's half of #361 (Decision 856). A trigger's `notify_url` was
refused at loopback, the unspecified address, link-local and multicast, so
`http://169.254.169.254/` was turned away, but `fd00:ec2::254` and `100.100.100.200`
were not. The chart leaves the plane's egress open, so a trigger naming either, as an
address or by a name answering with one, had the plane post there.

- **One list.** `Troupe.Plane.Triggers.Notify` no longer keeps its own clauses for
  loopback, the unspecified address and link-local. It asks
  `Troupe.WorkerProfile.Reach.refusal/1`, now public, which reads the list a worker's
  endpoints are refused from (`@refused`, Decisions 758 and 856) and takes an address as
  `:inet` gives one as well as a host as written. The list stays in the protocol app,
  where the operator and the plane can both read it; the next metadata address is added
  there once and refused in both. The kind it returns is the plane's sentence:
  `is not loopback`, `is not link-local`, `is not the unspecified address`, and now
  `is not a cloud metadata address`.
- **The plane's own: multicast and the whole shared address space.** Multicast stays the
  plane's alone, as before. `100.64.0.0/10` is refused whole, `is not in the shared
  address space`, which is not what 856 chose for a worker: there an address in it is
  admitted when given as that address, because a hosted object store or an
  installation's gateway may answer there. The plane differs because nothing holds its
  egress and because a `notify_url` is posted to on a name's word at send. A webhook
  receiver at an address in that range (a CGNAT overlay or a tailnet) is refused, and is
  given at a private or a public address instead. The private ranges stay open to it, as
  they were; the egress allowlist governs those.
- **Every spelling.** The check parses an address as a connection would, so the
  spellings 856's tests use (`FD00:EC2:0:0::254`, `::ffff:100.100.100.200`) and older v4
  ones (`1684301000`, `0144.0144.0144.0310`) are refused as the address they name. At
  send every address the name answers is checked (Decision 461), so one bad answer among
  good ones refuses it.
- **A resolver stand-in.** `:notify_resolver` in the plane's application environment, a
  function of a hostname to its addresses, replaces DNS at send, as `:egress_allowed`
  replaces the policy. The tests say what each name answers and never ask the network.
- **Proof:** the plane's `trigger_notify_test.exs` (each metadata address in every
  spelling, addresses across `100.64.0.0/10` and its v4-mapped form, refused at save and
  at send with the sentence; the edges `100.63.255.255`, `100.128.0.0` and
  `fd00:ec2::253` and the private ranges admitted; a name answering each metadata,
  shared, link-local and loopback address, and one answering a good and a bad address,
  refused at send and by `deliver/3`) and the protocol's `reach_test.exs` (`refusal/1`
  for hosts and for addresses). The new cases failed on the chunk tip. Not changed: the
  check at send and the connection resolve the name separately.
