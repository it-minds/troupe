---
number: 741
title: A person's own MCP server that wants them signed in, rather than a machine, is signed in to by the daemon, with PKCE and a loopback redirect, and its tokens never leave the person's machine
date: 2026-10-01
status: accepted
issue: 300
paths:
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/mcp/oauth.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/sign_in.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/store.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/tokens.ex
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
gist: A person's own MCP server that wants them signed in, rather than a machine, is signed in to by the daemon, with PKCE and a loopback redirect, and…
---

- **Discovery, as the MCP authorization specification orders it.** Scopes are the entry's,
  else the `401`'s, else the metadata's `scopes_supported`, and `offline_access` is added
  when the authorization server offers it, since without a refresh token a person signs in
  every hour. Every URL that carries a sign-in is `https`, or `http` on loopback. Two
  deliberate departures, each with a switch: the specification has a client refuse an
  authorization server whose metadata does not list `code_challenge_methods_supported`,
  and OpenID Connect discovery does not define the field, so one that says nothing is used
  with S256 anyway and only one that lists other methods is refused; and the resource
  indicator (RFC 8707), sent by default as the server's canonical URL in the authorization
  and token requests, is left out with `resource: false` for an authorization server that
  refuses it, where the scopes say which API a token is for.
- **The daemon runs the sign-in** (`Troupe.MCP.OAuth`, `Troupe.MCP.OAuth.SignIn`), because
  it is the process that calls the server and runs the person's other servers: the
  authorization code flow with PKCE (S256) and a `state`, and a listener on the loopback
  address the redirect names, on any free port unless the entry fixes one (RFC 8252 §7.3),
  for the one answer; anything else that arrives there is turned away, and an answer with
  another `state` is not this sign-in's. Signing in to a workspace's server waits for the
  workspace's question (700), since its `oauth` came with the repository and says where a
  token of the person's would go.
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
  tokens and is the store's only writer, because a public client's refresh tokens rotate
  and two sessions refreshing at once would spend one twice. A call that comes back `401`
  is refreshed, or given the token another session just refreshed, and tried once more; a
  refused refresh (`invalid_grant`) or a second `401` drops the tokens, keeps the account,
  and marks the sign-in `expired`. The model then gets `sign_in_required` as a tool result
  it can relay, like an unconnected person-mode server, and the session's server shows
  `sign_in` in `mcp.status`, which both clients draw as "sign in again".
- **A pod session gets none of this yet, and never the token.** The path is there in the
  protocol: a client offers tools it hosts through `tools.register` with a consent round
  trip, and serves `tool.invoke` (section 8); the pod sees names, schemas, arguments and
  results, and the call is made on the person's machine.
