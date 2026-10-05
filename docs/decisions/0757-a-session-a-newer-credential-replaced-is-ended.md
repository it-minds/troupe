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

Issue #358, defect D51, and two of the things 746 left
out of its slice. 746 kept a server's MCP session under its URL and a hash of the
call's headers and ended it only when its holder stopped. A pod calling a server as
its profile (747) gets a new token about once an hour, and each opened a new session
and left the one before open at the server until the pod stopped; a daemon's
refreshed sign-in (741) did the same for as long as the local session ran. A bundle
that dropped a server left its sessions open. And a server that answers a session it
has forgotten with `400` rather than the specification's `404` failed every call
after it restarted, until the pod did.
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
- **Proof:** `Troupe.MCPHandshakeTest`, against `test/support/fake_mcp.exs`, which
  now takes `forgotten: 400` and `bad_calls: true`: a credential that replaced another
  ends the session the other opened and leaves a person's be; a session the server
  answers `400` for is opened again once and the call goes through; a `400` a new
  session does not cure is the call's error after one retry, with one session left.
  `Troupe.Worker.MCPTest`: a profile's renewed token, through `:profile_tokens`, ends
  the session the token before it opened, and a bundle that drops a server ends the
  session discovery opened for it, lets go of a person's and keeps the other
  server's. All five failed on the tip of `development-2026-10-03`.
