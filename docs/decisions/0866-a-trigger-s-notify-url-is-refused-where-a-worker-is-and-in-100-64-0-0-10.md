---
number: 866
title: "A trigger's notify_url is refused at every address a worker's endpoint is, read from Reach's one list, and anywhere in 100.64.0.0/10, by literal or by a name that resolves there, and is posted to the address checked; every IPv6 spelling of a v4 address is judged as it"
date: 2026-10-11
status: accepted
issue: 588
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers/notify.ex
  - apps/troupe_plane/test/troupe/plane/trigger_notify_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
  - apps/troupe_protocol/test/troupe/worker_profile/reach_test.exs
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - docs/admin/bundles-and-triggers.md
symbols:
  - Troupe.WorkerProfile.Reach.refusal/1
  - Troupe.WorkerProfile.Reach.ipv4/1
gist: "notify_url: Reach.refusal/1's addresses and all of 100.64/10 refused, posted to the checked address; NAT64/6to4/compat judged as v4; NAT64 denied"
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
- **Posted to the address checked.** The check at send (Decision 461) resolved the name
  and the connection then resolved it again, so a name answering a good address to the
  check and a refused one a moment later (a rebind with a short lifetime, a round robin)
  passed and was posted to where no check looked. The request now goes to the first
  address the check passed, a v4 one when there is one, as the connection would have
  chosen: the URL names that address and the connection asks DNS nothing. The name goes
  as the `Host` header, and as Mint's `:hostname`, which is the TLS server name and the
  name the certificate is checked against. A literal in an older spelling
  (`1684301000`) is written as the address it was read as. Req keeps one connection pool
  per name this way, which for a plane's few notification targets is nothing.
- **Every spelling.** The check parses an address as a connection would, so the
  spellings 856's tests use (`FD00:EC2:0:0::254`, `::ffff:100.100.100.200`) and older v4
  ones (`1684301000`, `0144.0144.0144.0310`) are refused as the address they name. At
  send every address the name answers is checked, so one bad answer among good ones
  refuses it.
- **IPv6 spellings of a v4 address, for workers too.** `Reach.ipv4/1` reads the v4
  address in v4-mapped (`::ffff:a.b.c.d`), IPv4-compatible (`::a.b.c.d`, but `::` and
  `::1`, which are their own), NAT64's well-known prefix (`64:ff9b::a.b.c.d`) and 6to4
  (`2002:aabb:ccdd::/48`), and `refusal/1` judges that address. A profile's endpoint and a
  `notify_url` written so are refused as the address is. None of those prefixes overlaps
  a refused IPv6 block, so nothing is lost by judging the v4 address alone. A rule that
  admits an endpoint is still written for the address as given: only a v4-mapped one is
  the v4 address on the wire, and the others are reached as IPv6, through a translator or
  a relay.
- **The Cilium deny takes NAT64's spelling, not the others.** 856 denies by address
  because a `toFQDNs` rule admits a name at whatever address its DNS answer carries. In
  a cluster with NAT64, a DNS64 resolver answers a name whose only address is
  `169.254.169.254` with `64:ff9b::a9fe:a9fe`, and a translator carries the pod's packets
  on to the v4 address. RFC 6052 has a translator drop a well-known-prefix address naming
  a non-global one, which these all are, but nothing here can know the translator does.
  So the deny adds the v4 blocks in that prefix, `64:ff9b::a9fe:0/112` and
  `64:ff9b::6464:64c8/128`, computed from the same list. 6to4 and IPv4-compatible
  addresses are not added: no DNS64 answers with them, a pod has no route to a 6to4 relay
  (RFC 7526 retired them) and none for IPv4-compatible addresses, so a name leading there
  reaches nothing. A network-specific NAT64 prefix (`64:ff9b:1::/48` or a provider's own)
  is not known here and is not covered.
- **A resolver stand-in.** `:notify_resolver` in the plane's application environment, a
  function of a hostname to its addresses, replaces DNS at send, as `:egress_allowed`
  replaces the policy. The tests say what each name answers and never ask the network.
- **Proof:** the plane's `trigger_notify_test.exs` (each metadata address in every
  spelling, NAT64, IPv4-compatible and 6to4 included, addresses across `100.64.0.0/10`,
  refused at save and at send with the sentence; the edges `100.63.255.255`,
  `100.128.0.0` and `fd00:ec2::253`, the private ranges and NAT64 and 6to4 spellings of a
  public address admitted; a name answering each metadata, shared, link-local and
  loopback address, its DNS64 answer, and one answering a good and a bad address, refused
  at send and by `deliver/3`; and a name answering the machine's own address once and
  loopback after, posted to at that address with the name as `Host` and asked of the
  resolver once, against a real listener), the protocol's `reach_test.exs` (`refusal/1`
  for hosts and for addresses in every spelling, `ipv4/1`, an endpoint in NAT64 spelling
  refused or admitted as written, and the deny's NAT64 blocks) and the operator's
  `resources_test.exs` (the deny with them). The new cases failed on the chunk tip. Not
  checked: an `https` target, where Mint's `:hostname` gives the server name and the
  certificate check; and a live Cilium with NAT64.
