---
number: 746
title: An MCP server is opened with the lifecycle's handshake, and the session it issues is kept by whoever calls it, per server and credential, opened again once on a `404`, and ended when the caller stops
date: 2026-10-01
status: accepted
issue: 319
paths:
  - apps/troupe_core/lib/troupe/registry.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/support/fake_mcp.exs
  - apps/troupe_core/test/support/fake_oauth.exs
  - apps/troupe_core/test/troupe/mcp_handshake_test.exs
  - apps/troupe_core/test/troupe/mcp_test.exs
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/mcp/sessions.ex
  - apps/troupe_worker/lib/troupe/worker/application.ex
  - apps/troupe_worker/lib/troupe/worker/mcp.ex
  - apps/troupe_worker/test/troupe/worker/mcp_test.exs
gist: An MCP server is opened with the lifecycle's handshake, and the session it issues is kept by whoever calls it, per server and credential, opened…
---

Issue #319. `Troupe.MCP.Client` sent `tools/list`
and `tools/call` as lone POSTs with no `initialize` before them and kept nothing a
server answered, so a server that keeps state per client, and refuses a request
without the `Mcp-Session-Id` its `initialize` issued, could not be used from a local
session or a pod at all. That is the handshake 741 left out.
- **The handshake, once.** Before the first request to a server: `initialize` with
  the version Troupe speaks (`2025-06-18`), then `notifications/initialized`, whose
  answer is waited for and not read. Every request after carries the session id the
  server answered and, in `MCP-Protocol-Version`, the version it chose. A server that
  answers with no session id keeps none, and is called without one, as before.
- **Where the session lives.** `Troupe.MCP.Sessions`, an ETS table owned by a small
  process in the caller's supervision tree: one per local session, before
  `Troupe.Session.MCP`, and one per pod, in the worker's application before
  `Troupe.Worker.MCP`. A `Troupe.MCP.Server` carries the table as `sessions`, so the
  tools built at discovery find it, and `client.ex` stays the only module that talks
  to a server. Not one table for the node: `troupe_protocol` has no application to
  own it, and a session's MCP sessions should end with it. Not the state of
  `Troupe.Session.MCP`: the lookup is on every call's path, and a table is read
  without queueing.
- **The key** is the server's URL and a hash of the headers the call carries, which
  is the credential: a person's token and a profile's are two sessions, as a server
  that binds a session to whoever opened it needs, and a refreshed token opens a new
  one. Not keyed on whose credential it is, which the client does not see for every
  caller and which would present one token's session with another.
- **A forgotten session.** A `404` to a request that carried a session id drops it,
  opens one more and sends the request again, once. Two calls that open a session at
  once both finish the handshake; `:ets.insert_new/2` keeps one and the other is ended.
- **Its end.** The holder traps exits, and when its supervisor stops it, after the
  servers that use it, it sends each session a server issued a `DELETE`, a few seconds
  at most, whatever the answer (`405` included). That needs the credential the
  session was opened with, so it is kept beside it, except a person's on a pod, which
  is held for as long as a call takes (`Troupe.MCP.person_credential/2`): that session
  is left to the server's expiry. A call with no holder (`mcp.check` on a server not
  in a session) opens a session for its one request and ends it after;
  `Client.initialize/1`, the bare call sign-in discovery makes, ends any session it is
  given.
- **Out of this slice.** A `400` to a request that carried a session id, which some
  servers built from the SDKs' examples answer for a session they have forgotten, is
  an error rather than a reason to open another. A session left behind by a refreshed
  token is ended only when its holder stops. Streams the server opens (`GET`) and
  resuming one.
- **Proof:** `Troupe.MCPHandshakeTest`, against `test/support/fake_mcp.exs`, which
  refuses a request without its session id (`400`), with one it has forgotten (`404`)
  or with another credential than the session's (`403`), answers an older protocol
  version, and ends a session on `DELETE` or refuses it (`405`): an agent lists and
  calls the tools in one session carrying the version the server chose, a forgotten
  session is opened again once, the session ends when the local session stops and a
  `405` is let be, two credentials are two sessions, a server that keeps none is
  called without one, and a check's session lasts its one request; and
  `Troupe.Worker.MCPTest`: discovery per server and credential, every session of a pod
  in the profile's one, a person's in their own, a forgotten one opened again, and the
  pod's stopping. The fakes in `Troupe.MCPTest` and `fake_oauth.exs` now answer the
  `notifications/initialized` they had never been sent, with `202`.
