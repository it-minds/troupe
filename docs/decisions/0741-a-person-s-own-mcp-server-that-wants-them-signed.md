---
number: 741
title: A person's own MCP server that wants them signed in, rather than a machine, is signed in to by the daemon, with PKCE and a loopback redirect, and its tokens never leave the person's machine
date: 2026-10-01
status: accepted
issue: 300
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/application.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/mcp/import.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/mcp/oauth.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/sign_in.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/store.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/tokens.ex
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/support/fake_oauth.exs
  - apps/troupe_core/test/troupe/mcp_oauth_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/test/troupe/gateway/mcp_sign_in_test.exs
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/mcp/server.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/apps/desktop/src/views/Servers.tsx
  - clients/gui/apps/desktop/test/servers-panel.test.tsx
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/test/local-sources.test.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/browser.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/mcp_page_test.exs
  - docs/admin/bundles-and-triggers.md
gist: A person's own MCP server that wants them signed in, rather than a machine, is signed in to by the daemon, with PKCE and a loopback redirect, and…
---

Issue #300, the local slice. What was there: a bundle
server is called from the pod with one shared token from a Secret, which such a
server refuses; a person-mode bundle server reads a value the person pasted into the
key manager, not a sign-in that runs out every hour; and a `url` in the person's
`mcp.json` (700) was the one-shot HTTP client with no credential at all, `headers`
dropped on import. A server that publishes OAuth protected-resource metadata, answers
`401` with `WWW-Authenticate: Bearer resource_metadata="…"`, and has an authorization
server with no dynamic registration could not be used from Troupe.
- **What the person writes.** `oauth` on the entry, in `mcp.json` and in
  `config.yaml`'s `mcp:`: `client_id`, required, a public client registered in
  advance; `scopes`, `redirect_uri` (a loopback `http` URL, a fixed port when the
  client was registered with one), `resource: false` and `issuer`, each optional.
  Import reads `clientId`, `redirectUri` and `callbackPort` too. An `oauth` with no
  `client_id`, one on a `command`, or a redirect that is not loopback refuses the
  server, naming why. The fingerprint (700) takes the client and the issuer, so a
  workspace's server whose `oauth` changed is asked about again.
- **Discovery, as the MCP authorization specification orders it.** The server's
  `401` names its protected-resource metadata (RFC 9728), or the two well-known
  places are tried; that names the authorization server, unless `issuer` does; its
  metadata is tried at the three places for an issuer with a path (RFC 8414 and
  OpenID Connect, inserted, then OpenID Connect appended) and the two without. Scopes
  are the entry's, else the `401`'s, else the metadata's `scopes_supported`, and
  `offline_access` is added when the authorization server offers it, since without a
  refresh token a person signs in every hour. Every URL that carries a sign-in is
  `https`, or `http` on loopback. Two deliberate departures, each with a switch: the
  specification has a client refuse an authorization server whose metadata does not
  list `code_challenge_methods_supported`, and OpenID Connect discovery does not
  define the field, so one that says nothing is used with S256 anyway and only one
  that lists other methods is refused; and the resource indicator (RFC 8707), sent
  by default as the server's canonical URL in the authorization and token requests,
  is left out with `resource: false` for an authorization server that refuses it,
  where the scopes say which API a token is for.
- **The daemon runs the sign-in** (`Troupe.MCP.OAuth`, `Troupe.MCP.OAuth.SignIn`),
  because it is the process that calls the server and runs the person's other
  servers: the authorization code flow with PKCE (S256) and a `state`, and a
  listener on the loopback address the redirect names, on any free port unless the
  entry fixes one (RFC 8252 §7.3), for the one answer; anything else that arrives
  there is turned away, and an answer with another `state` is not this sign-in's.
  It waits five minutes; a second sign-in replaces the first. `mcp.sign_in` answers
  the URL and the redirect, and the TUI (`/mcp sign-in`, `s` on the page) and the
  desktop app (**Sign in** on "Servers and skills") open it and show the URL for a
  browser that did not open; the browser must be on the daemon's machine. Signing in
  to a workspace's server waits for the workspace's question (700), since its
  `oauth` came with the repository and says where a token of the person's would go.
- **Where the tokens live.** `<state>/mcp-oauth.json` (`Troupe.MCP.OAuth.Store`),
  restricted to its owner before anything is written into it, renamed into place,
  never kept as a `.previous`. Not the OS keychain, because the daemon has none in
  this build (the model key is in `config.yaml` for the same reason) and a keychain
  only the desktop app could read would leave a terminal-only person with nothing;
  not `mcp.json`, which people link, copy and commit; not the configuration
  directory, which people keep in their dotfiles. Nothing of a token is in an answer,
  an event or a log line: `mcp.list` carries `auth`, `{state, account, error}`, and
  `account` is read from the ID token's claims for showing only.
- **Use, refresh, and the `401`.** One process (`Troupe.MCP.OAuth.Tokens`) hands out
  tokens and is the store's only writer, because a public client's refresh tokens
  rotate and two sessions refreshing at once would spend one twice. A token is
  refreshed a minute before it runs out. A call that comes back `401` is refreshed,
  or given the token another session just refreshed, and tried once more; a refused
  refresh (`invalid_grant`) or a second `401` drops the tokens, keeps the account,
  and marks the sign-in `expired`. The model then gets `sign_in_required` as a tool
  result it can relay, like an unconnected person-mode server, and the session's
  server shows `sign_in` in `mcp.status`, which both clients draw as "sign in again".
  A refresh that could not be asked keeps the sign-in. When a sign-in lands, every
  local session that waits for the server asks it for its tools
  (`Troupe.Session.MCP.signed_in/1`). `mcp.sign_out` forgets it on this machine.
- **A pod session gets none of this yet, and never the token.** The path is there in
  the protocol: a client offers tools it hosts through `tools.register` with a
  consent round trip, and serves `tool.invoke` (section 8); the pod sees names,
  schemas, arguments and results, and the call is made on the person's machine. What
  is missing: a daemon method that lists a person's own servers' tools and calls one
  outside a session, and a client that registers them with a pod session it attaches
  to — the desktop app's library has `registerTools` and `onToolInvoke` and nothing
  uses them, and the TUI's remote connection answers no `tool.invoke` — with the
  consent shown to the person and the registration made again after a reconnect.
  That is the next slice, issue #308. A server without `oauth` that answers `401` is
  `error`, naming `oauth.client_id`, rather than unreachable.
- **Out of this slice.** Dynamic client registration and client ID metadata
  documents, for a provider that offers them, so a person needs no client id; a
  confidential client's secret; a step-up sign-in on `403 insufficient_scope`;
  revoking the refresh token at the provider on sign-out; the session handshake a
  stateful streamable-HTTP server wants (`initialize` and `Mcp-Session-Id`), which the
  one-shot client from 654 still does not make.
- **Proof:** `Troupe.MCPOAuthTest` (against `test/support/fake_oauth.exs`, an
  authorization server with a path issuer and no registration and a server that
  wants a person: the session waiting, discovery in order, PKCE, `state`, the resource
  indicator, the redirect, the tools with the token, one refresh for five askers, a
  `401` refreshed, a refused refresh turned into `sign_in_required` and back, a
  refusal kept, a forged answer turned away, the store's mode, no token in an event),
  `Troupe.Gateway.MCPSignInTest` (`mcp.sign_in`, `auth`, `mcp.sign_out` over the
  daemon's socket, and the refusals), the TUI's `Troupe.MCPPageTest` and the GUI's
  `local-sources.test.ts` and `servers-panel.test.tsx`.
