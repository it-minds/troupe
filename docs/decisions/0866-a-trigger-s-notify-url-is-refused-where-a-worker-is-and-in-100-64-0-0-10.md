---
number: 866
title: "A trigger's notify_url is refused at every address a worker's endpoint is, read from Reach's one list, and anywhere in 100.64.0.0/10, by literal or by a name that resolves there, and is posted to the address checked; every IPv6 spelling of a v4 address is judged as it"
date: 2026-10-11
status: accepted
issue: 588
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers/notify.ex
  - apps/troupe_protocol/lib/troupe/worker_profile/reach.ex
symbols:
  - Troupe.WorkerProfile.Reach.refusal/1
  - Troupe.WorkerProfile.Reach.ipv4/1
gist: "notify_url: Reach.refusal/1's addresses and all of 100.64/10 refused, posted to the checked address; NAT64/6to4/compat judged as v4; NAT64 denied"
---

- **One list.** `Troupe.Plane.Triggers.Notify` no longer keeps its own clauses for
  loopback, the unspecified address and link-local. It asks
  `Troupe.WorkerProfile.Reach.refusal/1`, now public, which reads the list a worker's
  endpoints are refused from (`@refused`, Decisions 758 and 856) and takes an address as
  `:inet` gives one as well as a host as written. The list stays in the protocol app,
  where the operator and the plane can both read it; the next metadata address is added
  there once and refused in both.
- **The plane's own: multicast and the whole shared address space.** Multicast stays the
  plane's alone, as before. `100.64.0.0/10` is refused whole, `is not in the shared
  address space`, which is not what 856 chose for a worker: there an address in it is
  admitted when given as that address, because a hosted object store or an
  installation's gateway may answer there. The plane differs because nothing holds its
  egress and because a `notify_url` is posted to on a name's word at send. A webhook
  receiver at an address in that range (a CGNAT overlay or a tailnet) is refused, and is
  given at a private or a public address instead. The private ranges stay open to it, as
  they were; the egress allowlist governs those.
- **Posted to the address checked.** The request now goes to the first address the check
  passed, a v4 one when there is one, as the connection would have chosen: the URL names
  that address and the connection asks DNS nothing. The name goes as the `Host` header,
  and as Mint's `:hostname`, which is the TLS server name and the name the certificate is
  checked against. A literal in an older spelling (`1684301000`) is written as the address
  it was read as.
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
