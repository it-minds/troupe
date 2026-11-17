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
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/mcp/sessions.ex
  - apps/troupe_worker/lib/troupe/worker/application.ex
  - apps/troupe_worker/lib/troupe/worker/mcp.ex
gist: An MCP server is opened with the lifecycle's handshake, and the session it issues is kept by whoever calls it, per server and credential, opened…
---

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
