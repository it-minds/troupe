---
number: 757
title: A session a newer credential replaced is ended when the new one is kept, a server a bundle drops has its sessions ended, and a `400` to a request in a session is a forgotten session, once
date: 2026-10-03
status: accepted
issue: 358
paths:
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/mcp/sessions.ex
  - apps/troupe_worker/lib/troupe/worker/mcp.ex
gist: A session a newer credential replaced is ended when the new one is kept, a server a bundle drops has its sessions ended, and a `400` to a request…
---

- **What a session is kept for.** The key does not change: two credentials are two
  sessions, and a person's and a profile's are never one. Beside it each session
  records the server it was opened for, by URL and name, and its credential mode
  (`Sessions.kept_for/1`). A call that keeps a new session takes out any kept for the
  same under another key and ends it with a `DELETE` carrying its own credential,
  best-effort and `405` let be, before its request goes out. Not keyed on the server
  and mode instead: a session would then be presented with a token it was not opened
  with, which a server that binds a session to a credential refuses.
- **Not a person's.** On a person-mode server every person is a caller of their own,
  the client does not see whose credential a call carries, and on a pod it does not
  hold a person's credential to end their session with (746). A person's session a
  refreshed token left behind stays in the pod's table until the pod stops or the
  bundle drops the server, and at the server until it expires it.
- **Two tokens at once.** A call still holding the old token while another holds the
  new may open one more session in the overlap, and each one kept ends the other's;
  once the old token is no longer handed out (747 hands out one), that stops.
- **A bundle that drops a server.** `Troupe.Worker.MCP.put_servers/2` keeps only the
  sessions of the new bundle's servers (`Sessions.retain/2`) and ends the rest before
  it discovers again. A server still there by URL, name and mode keeps its session,
  and one whose credential changed has its session replaced by discovery, as above.
- **A `400` to a request that carried a session id** drops the session, ends it (a
  server may answer `400` for something else and still hold it), opens one more and
  sends the request again, once, as a `404` does. A `400` the new session does not
  cure is the call's error: one handshake more for such a call, never a loop. A
  `400` to a request without a session id is the call's, as before. Read from the
  SDKs: the TypeScript SDK 1.30.0's transport answers `404`, but its example servers
  look the session up before it and answer an unknown one with `400`, `DELETE`
  included; the Python SDK's session manager answered `400` through at least 1.23.0
  and answers `404` on its main branch now.
