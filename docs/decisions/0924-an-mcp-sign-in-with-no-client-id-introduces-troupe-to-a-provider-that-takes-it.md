---
number: 924
title: "A person's MCP sign-in with no client id presents Troupe's client ID metadata document or registers a public client where the provider takes one, keeping it beside the tokens; and a call to a person's tool that left the session says whose it was"
date: 2026-10-18
status: accepted
issue: 585
supersedes: [741, 861]
paths:
  - apps/troupe_core/lib/troupe/mcp/oauth.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/sign_in.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/store.ex
  - apps/troupe_core/lib/troupe/mcp/oauth/tokens.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/test/support/fake_oauth.exs
  - apps/troupe_core/test/troupe/mcp_oauth_test.exs
  - docs/oauth/client.json
  - docs/user/configuration.md
  - apps/troupe_core/lib/troupe/session/client_tools.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/test/troupe/session/client_tools_test.exs
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/gui/packages/client/src/transcript.ts
  - PROTOCOL.md
symbols:
  - Troupe.MCP.OAuth.client/3
  - Troupe.MCP.OAuth.client_metadata/1
  - Troupe.Session.ClientTools.departed/2
gist: "No client_id: metadata document, else RFC 7591 public client (loopback, no secret) kept in state; entry's id wins. A gone client tool says whose"
---

Issues #585 and #592, both from #308's pod side. Two decisions, recorded together because
one number was reserved for the slot that made them; each part stands alone.

## A sign-in with no client id (#585)

Decision 741 made `oauth.client_id` required: a provider with no dynamic registration has
no other way to know Troupe. Many do have one. The MCP authorization specification lists,
in order, a client registered in advance, a client ID metadata document, and dynamic client
registration (RFC 7591), and only then asking the person. Troupe now does the same, and
this replaces 741's "`client_id`, required" and "an `oauth` with no `client_id` refuses
the server".

- **What the person writes.** An `oauth` with no `client_id` (`"oauth": {}` is enough)
  is a server that wants a sign-in, with Troupe introducing itself. The entry's
  `client_id` still wins whenever there is one: whoever runs the server registered it for
  a reason (a confidential tenant, consent already granted to it, a policy on unknown
  clients), and nothing Troupe registers itself overrides that. A server with no `oauth`
  at all stays a server that takes no sign-in, so a URL that answers `401` is not signed
  in to by surprise; its error now says that `{}` is enough where the provider registers
  clients.
- **The order: the metadata document, then registration.** Where the authorization
  server's metadata says `client_id_metadata_document_supported`, the client id is the URL
  of Troupe's document, `https://it-minds.github.io/troupe/oauth/client.json` (published
  from `docs/oauth/client.json` by the documentation site), and nothing is registered or
  kept. That is the specification's order, and it leaves no record at the provider for
  each machine. An entry that fixes its own `redirect_uri` skips it, since the document
  lists only the loopback redirects Troupe listens on by default. Else, where the metadata
  names a `registration_endpoint`, Troupe registers. Else the sign-in answers the sentence
  asking for a client id, as the configuration did before.
- **What Troupe says it is.** `client_name: Troupe`, `client_uri` the repository, the
  loopback redirect, `grant_types: [authorization_code, refresh_token]`,
  `response_types: [code]`, and `token_endpoint_auth_method: none` (`client_metadata/1`,
  and the same fields in the published document). A public client because a program on a
  person's machine has nowhere to keep a secret that the person's other programs cannot
  read, and OAuth 2.1 and RFC 8252 say a native app is a public client protected by PKCE,
  which every sign-in already uses. No `scope`, `contacts`, `logo_uri` or software
  statement: the scopes are asked for at each sign-in, and anything more is a field a
  provider may refuse. A provider that registers Troupe as a client that authenticates
  anyway (a `client_secret`, `client_secret_basic`) is refused with a sentence asking for
  a `client_id`, rather than storing a secret that would be no authentication at all; no
  secret and no `registration_access_token` is ever kept.
- **The redirect, with its port.** With no `redirect_uri` in the entry, Troupe picks a free
  loopback port, registers `http://127.0.0.1:<port>/callback` and keeps it with the client,
  so every later sign-in listens on that same port. A provider that matches a redirect
  exactly takes it, and one that matches loopback without the port (RFC 8252 section 7.3)
  takes it too. The listener sets `reuseaddr`, so the port a sign-in just answered on can
  be listened on again while its connection waits out its time; another listener on it is
  still refused, and when something else holds the port, Troupe registers again on a free
  one. The metadata document lists the port-less loopback redirects instead, since it is
  one document for every machine.
- **Kept beside the tokens, never in a workspace.** `<state>/mcp-oauth-clients.json`,
  written whole and owner-only exactly as `mcp-oauth.json` is, and only by
  `Troupe.MCP.OAuth.Tokens`: one client per authorization server and redirect, with the
  issuer, the client id, the redirect, the registration endpoint and when. Not
  `mcp.json`, which a workspace may carry and a person copies between machines; a
  registration is this machine's. Each sign-in's entry records which registered client it
  was made as (`registered`), and its `client_id`, so a refresh and a revocation go as that
  client. A sign-out leaves the client: it is Troupe's record at the provider, not the
  person's grant.
- **Registered again when the provider says it is gone.** A token endpoint that answers
  `invalid_client` to a code or a refresh, or an authorization redirect that comes back
  `invalid_client` or `unauthorized_client`, for a client Troupe registered, forgets it
  here: the sign-in ends as any refused one does, the person is told to sign in again, and
  that sign-in registers a new client. Not retried silently inside the same sign-in, since
  the person is in the middle of a browser step at the provider either way.
- **Every URL held to Decision 875.** The registration endpoint is checked as the token
  endpoint is (`outbound/2`) and the request goes to the address checked, with no
  redirects followed.

**Proof:** `Troupe.MCPOAuthTest`, "an entry with no client_id", against
`fake_oauth.exs`'s `registration` and `metadata_document` modes: the metadata Troupe sends
and that it holds no secret; the sign-in made as the registered client and the client kept
owner-only in the state directory; the next sign-in reusing it, port and all, and a
refresh going as it; a provider that forgot it, the client forgotten here and registered
anew; a port held by something else; the document presented and nothing registered; a
configured `client_id` winning; neither offered, the sentence; a confidential-only
registration refused; and the published document matching what Troupe registers.

## A person's tool that left (#592)

Decision 861 said a model that names a person's tool after it went gets the ordinary
"There is no tool named client.…", and that neither client draws a line when somebody's
tools go. Both changed.

- **The model is told whose it was.** A call to a `client.` tool that a client offered
  this session once and nobody offers now, in that turn or a later one, is answered with
  the tool's name, whose it was, that their client left the session (or that they took it
  back, for `tools.unregister`), that it did not run, and to do the work another way or
  ask them to offer it again (`Troupe.Session.ClientTools.departed/2`, read from the
  session's log so it holds across a restart). A name nobody ever offered the session is
  still "There is no tool named …": the model can now tell a name it got wrong from a
  person who left. A call in flight when the client went keeps 861's own sentence.
- **`tools_unregistered` says whose.** It carries the registration's actor as the event's
  actor and its subject as `actor`, as `session_tainted` does; a registration made with no
  actor is the subject's. A log written before has neither, and reads as "somebody's".
- **Both clients draw one line for it**: whose, how many and why, in the same words
  ("Ada's 2 tools are no longer offered to the session, because their client left:
  client.notes.read, client.notes.search"), beside the line they already drew for
  `session_tainted`.

**Proof:** `Troupe.Session.ClientToolsTest` (the event's actor and the model's sentence,
and the unknown name's), the TUI's `remote_translate_test.exs`, the desktop app's
`transcript.test.ts` and `own-servers.test.tsx`.
