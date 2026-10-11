---
number: 875
title: "Every URL the daemon calls for a person's own MCP server and its sign-in is resolved, every address it answers is checked against Decision 856's list, and the request goes to the address checked; loopback and the private ranges stay allowed"
date: 2026-10-12
status: accepted
issue: 618
supersedes: [872]
paths:
  - apps/troupe_protocol/lib/troupe/mcp/address.ex
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/mcp/server.ex
  - apps/troupe_protocol/lib/troupe/mcp/sessions.ex
  - apps/troupe_protocol/test/troupe/mcp/address_test.exs
  - apps/troupe_core/lib/troupe/mcp/oauth.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/support/fake_oauth.exs
  - apps/troupe_core/test/troupe/mcp_oauth_address_test.exs
  - docs/user/configuration.md
symbols:
  - Troupe.MCP.Address
  - Troupe.MCP.Address.target/1
  - Troupe.MCP.OAuth.outbound/2
gist: "MCP/OAuth URLs: name resolved, every answer checked (no link-local, metadata, unspecified; loopback and private OK), request pinned to it, redirects re-checked"
---

Issue #618, the daemon's half of what Decision 866 did for the plane. A person's own MCP
server and its authorization server were not held to one rule. `OAuth.outbound/2` held
the token and revocation endpoints to `https` (or `http` on loopback) and refused
link-local, cloud-metadata and unspecified addresses from Decision 856's list, but only an
address written in the URL: a name that resolved to `169.254.169.254` passed, and was
called. The server's URL, which is sent the token, the metadata URLs and the
authorization endpoint were held to `secure/2` alone. The maintainer decided the shape on
2026-10-12 (#618's comment): a person's own server may be on a private address, every URL
is resolved, a link-local, metadata or unspecified address is refused wherever the name
points, the connection goes to the address checked, and loopback stays.

- **One rule, one module.** `Troupe.MCP.Address`, in the protocol app beside the MCP
  client. `target/1` resolves a name in both families (an address written as one is its
  own answer, in any spelling `:inet.parse_address/1` reads, `2852039166` too), checks
  every address with `Troupe.WorkerProfile.Reach.refusal/1`, and answers the first, a v4
  one when there is one, or a `Refused` naming the host, the address and its kind. One
  refused answer among good ones refuses the name. The list is 856's and 866's, so the
  next metadata address is refused here when it is added there, in every spelling
  `Reach.ipv4/1` reads (v4-mapped, NAT64, 6to4, IPv4-compatible).
- **What stays open.** Loopback, for a server a person runs on their own machine (741),
  and everything else not on the list: the private ranges (`10/8`, `172.16/12`,
  `192.168/16`, `fc00::/7`, `fd00:ec2::254` aside), where an intranet's servers are, and
  the shared address space but `100.100.100.200`. This is where the daemon differs from
  the plane, which refuses loopback and all of `100.64.0.0/10` (866): the plane posts on
  an administrator's word from inside a cluster, the daemon on a person's own, on their own
  machine.
- **The request goes to the address checked.** `Address` is the request's Req adapter
  (`options/0`): the URL is rewritten to the address `target/1` answered and handed to
  Req's own Finch adapter, so the connection asks DNS nothing and a name that answers one
  address to the check and another a moment later is not sent where no check looked. The
  name goes as the `Host` header and as Mint's `:hostname`, which is the TLS server name
  and the name the certificate is checked against. What comes back is paired with the
  request as it was, named, so a redirect Req follows is read against the name and comes
  back through the adapter to be resolved and checked before it is sent. Doing it as the
  adapter, rather than resolving before `Req.request/1` as 866 does, is what holds the
  redirects to the rule; a `notify_url` follows none.
- **Which requests.** The MCP client's, for a server with `pinned` set: every request of
  a session (the handshake, the calls, the `DELETE` that ends it, which carries `pinned`
  in the session it ends). The daemon sets it on every URL server it builds
  (`Troupe.Session.MCP`'s `server_of/3`, which `mcp.call` and `mcp.tools` use too) and on
  discovery's unauthenticated probe; a file cannot set or clear it. A pod's servers are
  unchanged: its egress is its network policy's (856). And every request
  `Troupe.MCP.OAuth` makes: the protected-resource metadata, the authorization server's
  metadata, the token endpoint (the exchange and every refresh) and the revocation
  endpoint.
- **Checked before anything is sent, too.** `outbound/2` resolves now, and holds the
  server's URL to it as well as the token and revocation endpoints, the three a token
  goes to: discovery refuses a server or a token endpoint whose name leads to a refused
  address, with the sentence (`the token endpoint (https://…) resolves to 169.254.169.254,
  a link-local address`), before the person is sent to a browser for a sign-in that could
  not be redeemed. A name that resolves to nothing is refused there too (`does not
  resolve (nxdomain)`). A metadata document whose address is refused ends discovery with
  why, rather than being passed over as a place with nothing there. Each request is
  checked again when it is made; the two lookups may differ, and the second is the one
  the request goes to.
- **The authorization endpoint** is the person's browser's to open, not the daemon's, so
  nothing can pin it. Its name is resolved at discovery and refused at the same addresses,
  which turns away metadata that points the browser at one; a name that does not resolve
  on this machine is left to the browser, which may reach it through a proxy the daemon
  does not use. No registration endpoint is called (dynamic registration is out of 741's
  slice); one would go through `Address` like the rest.
- **The token endpoint follows no redirect.** A code or a refresh token goes to the
  endpoint the metadata named and nowhere it points, as the metadata and revocation
  requests already did. The MCP client still follows a server's redirects (a server
  mounted at `/mcp/` that redirects `/mcp` is common), each checked.
- **What a refusal looks like.** The client answers `{:error, sentence}`
  (`notes.example.test resolves to 169.254.169.254, a link-local address, and is not
  called`), which the server's line on the `/mcp` page shows; a lookup that answers
  nothing is the `Req.TransportError` a connection would have given. The scheme rule is
  `secure/2`'s, as before: `https`, or `http` to `127.0.0.1`, `::1` or `localhost`.
- **A resolver stand-in.** `:mcp_resolver` in `troupe_protocol`'s application
  environment, a function of a host name to its addresses, replaces DNS, as 866's
  `:notify_resolver` does; the tests say what each name answers. It takes a function only,
  which no flag or variable can write.
- **This supersedes** the part of Decision 872 that said a name is not resolved for the
  revocation and token endpoints' check.
- **Not done:** the plane's `Notify` keeps its own resolve-and-pin (866) rather than
  calling `Address`, since its rule differs and it follows no redirect; the two could share
  the mechanics. Happy-eyeballs fallback to a second address is not attempted, as Mint did
  not attempt it before.
- **Proof:** the protocol's `address_test.exs` (a name resolving to `169.254.169.254`
  refused with nothing sent; every metadata spelling, link-local and the unspecified
  address resolved and literal; one bad answer among good ones; the private ranges,
  `100.64.0.1` and `fd00:ec2::253` allowed; loopback by address and by name; a name
  answering loopback to the check and a metadata address after, sent to loopback with the
  name as `Host` and asked once, then refused; a redirect to a metadata name refused; TLS
  passing for the name in the certificate at the pinned address and failing
  `hostname_check_failed` for another name there; the MCP client's handshake, listing and
  `DELETE` all pinned, and a server named to a metadata address answered with the
  sentence) and core's `mcp_oauth_address_test.exs` (the reproduction, a token endpoint
  named to a metadata address, refused at discovery and on refresh; the server's URL, the
  resource metadata a `401` names, the authorization server's metadata, the authorization
  endpoint and the revocation endpoint each refused by name; an unresolved authorization
  endpoint left to the browser; a local session's server refused with the sentence; a
  token endpoint asked once per request and sent to loopback; a loopback server signing in
  by name; private addresses allowed; an unresolved token endpoint refused). On the chunk
  tip 10 of core's 12 failed, all but the two that pin what stays allowed.
