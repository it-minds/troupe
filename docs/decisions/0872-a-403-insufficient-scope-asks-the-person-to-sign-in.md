---
number: 872
title: "A 403 insufficient_scope from a person's own MCP server is the sign_in_required answer with the scope it named, and the person's next sign-in asks for it on top of what was granted, at the same authorization server; signing out revokes the refresh token at the provider when it can be told, and forgets it whether or not"
date: 2026-10-11
status: accepted
issue: 586
paths:
  - apps/troupe_core/lib/troupe/mcp/oauth.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/sign_in.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/store.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/tokens.ex
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/support/fake_oauth.exs
  - apps/troupe_core/test/troupe/mcp_oauth_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/test/troupe/gateway/mcp_call_test.exs
  - apps/troupe_gateway/test/troupe/gateway/mcp_sign_in_test.exs
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/cli/remote.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/mcp_page_test.exs
  - docs/user/configuration.md
  - docs/user/mcp.md
  - PROTOCOL.md
symbols:
  - Troupe.MCP.OAuth.authorized/2
  - Troupe.MCP.OAuth.sign_out/2
  - Troupe.MCP.OAuth.sign_out_all/2
  - Troupe.MCP.OAuth.outbound/2
gist: "403 insufficient_scope: sign_in_required + scope, kept as step_up; the person's sign-in asks granted+named at the metadata's issuer; sign-out revokes (RFC 7009), forgets anyway"
---

Issues #586 and #587, two items of Decision 741's "out of this slice" list (#308's last
paragraph). What was there: a person's own MCP server that answered a call `403` with
`WWW-Authenticate: Bearer error="insufficient_scope", scope="…"` was an ordinary failed
call ("the identity this call went out as may not use this tool"), and nothing asked the
person to grant the scope; and `mcp.sign_out` forgot the tokens in the daemon's state
directory but sent nothing to the provider, so the refresh token stayed good there until
it expired, and a copy of the state directory could still renew it.

**The step-up (#586).**

- **The answer.** The MCP client returns a `403` whose challenge says
  `insufficient_scope` as `{:insufficient_scope, header}`; any other `403` is the refusal
  it was. `OAuth.authorized/2` turns one that names a scope into
  `{:error, {:sign_in_required, scope}}`, and the tool's answer is the `sign_in_required`
  note a run-out sign-in gets, with `scope`, the scope the server named, and a hint the
  model relays. Listing the tools that way makes the session's server `sign_in`, saying
  the scope. One that names no scope leaves a sign-in nothing to ask for, and stays the
  refusal it was, described as such.
- **Where it is kept.** The named scope goes beside the sign-in in the store (`step_up`,
  through `Tokens`, the store's one writer), and `mcp.list`'s `auth` carries it as
  `step_up`; the TUI's `/mcp` page shows `wants <scope> — s`.
- **The scope asked for** is the union of what the next sign-in would ask anyway (the
  entry's, the `401`'s, the metadata's), what was granted (the token endpoint's `scope`,
  or what was asked when it said none) and what the server named, with `offline_access`
  as before. `mcp.sign_in` answers `scopes`, what the person is asked to grant, and the
  TUI's notice says it.
- **Where the sign-in goes.** Only the scope is read from the `403`. Its
  `resource_metadata` is not followed: the sign-in is discovered as any is, from the
  server's own `401` and protected-resource metadata, so a `403` cannot send the person to
  another authorization server. The suite's server names one elsewhere in every `403`, and
  nothing goes there.
- **Who decides.** Nothing signs in on its own. The step-up is a note the model relays and
  a line on the page; a sign-in starts only when the person asks for one (`s`,
  `/mcp sign-in`, **Sign in**), and the provider's consent page names the scopes.
- **The tokens held** are kept and used until the new sign-in lands, whose entry replaces
  the old one and drops `step_up`. A step-up the person refuses at the provider keeps the
  sign-in as it was, with the refusal as its last error.
- **Not chosen:** starting a sign-in from the `403` (a server could then open a consent
  page on the person's screen with any call), or following the `403`'s
  `resource_metadata` (an issuer change belongs to the server's metadata, which a fresh
  sign-in reads anyway).

**Revocation on sign-out (#587).**

- **What is revoked.** The refresh token, with `token_type_hint=refresh_token` and the
  client id (a public client authenticates with its id, RFC 7009 §2.1), at the
  `revocation_endpoint` the authorization server's metadata named at the sign-in, kept in
  the entry. An entry kept before this has the endpoint looked up from its issuer's
  metadata at sign-out. With no refresh token, the access token.
- **Forgotten first, then told.** `Tokens.take/1` removes the entry and answers it, and the
  revocation is sent outside that process. The issue's order was revoke then forget; taking
  first means no refresh can spend the token and keep a new one while the provider is
  asked, and the person waits no longer for the store. The outcome is the same: the
  sign-in is gone here whatever the provider says.
- **Where the token may go.** The revocation endpoint is held to what the token endpoint is
  (`OAuth.outbound/2`): `https`, or `http` on loopback, and not at an address on Decision
  856's list (`Reach.refusal/1`) — link-local, a cloud metadata address, the unspecified
  address — loopback kept, as `secure/2` has it. The token endpoint is now held to the same
  check, since both are sent the refresh token. A name is not resolved for the check, as
  for the token endpoint before.
- **When it cannot be told.** A refusal, a non-2xx answer, or no answer in five seconds
  (connect and receive) is `failed` with the reason; the tokens are forgotten anyway and
  the answer says the provider was not told. Metadata with no `revocation_endpoint` is
  `unsupported`. Nothing held is `none`. `mcp.sign_out` answers `revocation: {state,
  reason}`, and the TUI's page and `troupe logout` say it in one sentence.
- **`troupe logout`.** `mcp.sign_out` with `all: true` signs out of every entry in the
  store, by whatever name and in whatever workspace it was signed in from. `troupe logout`
  without a plane named, and `--all`, ask the daemon for it after the plane sign-out and
  print a line per server that held a sign-in. Naming a plane signs out of that plane
  alone: these sign-ins are no plane's, and signing out of a second plane should not end
  them. A daemon that is not running is not started (Decision 766 does not start one for
  the plane token either); the CLI reads the daemon's `mcp-oauth.json` for how many
  sign-ins it holds, never using what is in them, and says they were kept and why. A
  daemon that refuses the call (one from before this, which wants a `name`) is said to
  have kept them.

**Proof.** `Troupe.MCPOAuthTest`, against `fake_oauth.exs`, whose tokens now carry their
scopes, whose `write` tool wants `notes.write` and answers `403 insufficient_scope`
naming metadata elsewhere, and whose authorization server revokes at
`/tenant/revoke` or refuses, is slow, or names none: in a local session the `403` is the
note with the scope, nothing signs in or goes elsewhere, the tokens are kept and used, the
sign-in asks for the union at the same issuer, and the call goes through after it; a
refused step-up keeps the sign-in; sign-out revoked, refused, timed out, absent, link-local,
an old entry looked up, nothing held, and every sign-in at once; `outbound/2` over the list;
the client's `{:insufficient_scope, header}`. On the chunk's tip every new case failed (11
of 23). `Troupe.Gateway.MCPCallTest`: a pod session's agent calls a person's offered
`write` through the client, the pod's model gets the note with the scope, `mcp.list`
shows `step_up`, and after the person's sign-in `mcp.call` goes through.
`Troupe.Gateway.MCPSignInTest`: `revocation` in `mcp.sign_out`'s answer, and `all`. The
TUI's `MCPPageTest`: the page's `wants notes.write — s`, `s` asking for it, the sign-out
notice saying the provider revoked it, and `troupe logout` saying the sign-in was kept
while the daemon is not running (and starting none), then, with it running, signing out
of the server with its provider told.
