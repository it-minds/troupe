---
number: 723
title: With Cilium, an allowed host that is an IP address is admitted as that one address, by a `toCIDR` rule
date: 2026-09-29
status: accepted
issue: 251
paths:
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
gist: With Cilium, an allowed host that is an IP address is admitted as that one address, by a `toCIDR` rule
---

Issue #251. The `CiliumNetworkPolicy` wrote every
external host as a `toFQDNs` `matchName`, the installation's OpenBao and object store
among them since Decision 721, and Cilium learns what a `matchName` admits from the
DNS answers its proxy sees. Nothing looks an address up, so an object store at
`http://192.0.2.10:9000`, or an address a profile named, was admitted by nothing. A
host that parses strictly as an address (`:inet.parse_strict_address/1`) now goes
into one `toCIDR` rule beside the `toFQDNs` one, as `/32`, or `/128` for IPv6, in its
shortest form, and with no ports, as the FQDN rule has none. `toCIDR` rather than
`toCIDRSet`, which exists for `except`, and nothing here excepts anything. It does
not reach an address inside the cluster, because Cilium matches a pod, and a
Service's backends, by identity and not by CIDR; an in-cluster endpoint is still
named as a `*.svc` host, which is its namespace and port. Without Cilium nothing
changes. Proof: `resources_test.exs` (the platform's endpoints as IPv4 and IPv6
literals; a profile's own addresses beside its names).
