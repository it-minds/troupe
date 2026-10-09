---
number: 820
title: "An MCP server over HTTP is sent the headers its entry names, each written as it is or as an `{env:VAR}` read when the server starts; an import carries them and never copies a value written out; no keychain"
date: 2026-10-09
status: accepted
issue: 60
supersedes: [700]
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/mcp/import.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/support/fake_mcp.exs
  - apps/troupe_core/test/troupe/config/layers_test.exs
  - apps/troupe_core/test/troupe/mcp/import_test.exs
  - apps/troupe_core/test/troupe/mcp/local_test.exs
  - apps/troupe_core/test/troupe/mcp_handshake_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/test/troupe/gateway/local_sources_test.exs
  - apps/troupe_protocol/lib/troupe/mcp/client.ex
  - apps/troupe_protocol/lib/troupe/mcp/server.ex
  - apps/troupe_protocol/test/troupe/mcp/client_headers_test.exs
  - docs/user/configuration.md
symbols:
  - Troupe.MCP.Server.headers/1
  - Troupe.MCP.Server.header_problem/1
  - Troupe.MCP.Import.parse/2
  - Troupe.Session.MCP.format_status/1
gist: "MCP headers: literal or {env:VAR}, read at start, shown by name only; the credential wins a same-named one; a copy writes values as {env:VAR}; no keychain"
---

Issue #60, its last slice. What was there: an import dropped a server's `headers` with a
warning (700), and the HTTP client sent one header, the server's credential
(`Troupe.MCP.Server.headers/1`), so a server keyed with a static header (an `X-Api-Key`,
a token issued once) could not be used from a local session at all, imported or written
by hand.

- **What the person writes.** `headers` on a `url` entry, in `mcp.json` and in
  `config.yaml`'s `mcp:`: a map of name to string, each value as it is or with
  `{env:VAR}` in it, read as every other string of the entry is, when the layers are
  resolved, which is when a session starts its servers and when a reload or a check
  reads them again. An unset variable refuses the server, naming the variable, and
  nothing is sent in its place. The value read is held by the session's server and
  never written anywhere. A header on a `command` server is not sent. Refused, naming
  why, rather than dropped: a name that is not an HTTP token, a value with a line break
  or another control character (it would split the request), and a name the client
  sends itself (`Accept`, `Content-Type`, `Content-Length`, `Host`, `Connection`,
  `Transfer-Encoding`, `Mcp-Session-Id`, `Mcp-Protocol-Version`), since a person who
  wrote a header must not find out from the server that it never went.
- **Sent on every request.** `Server.headers/1` is what `Troupe.MCP.Client` reads for
  each request, so the headers go with `initialize` and `notifications/initialized` as
  with the listing and every call, and with the `DELETE` that ends the session, which
  keeps the headers it was opened with (746). The session key (746) is a hash of all of
  them: they are part of the credential, and a changed one opens another session.
- **The credential wins one of the same name.** On a server with `oauth` the sign-in's
  token is the `Authorization` that goes out, and a bundle's service credential its own
  header; an entry's header of that name, compared without case, is left out, so one
  goes. The token is the one kept fresh (741): refreshed before it runs out, tried again
  on a `401`, dropped when refused, and a second `Authorization` from a file would be a
  stale credential beside it. `oauth` is also the narrower statement of how the server is
  reached. On a server without `oauth`, an `Authorization` in `headers` is what goes out.
- **Shown by name.** `mcp.list` and `mcp.add`'s answers carry `headers` as names, as
  `env` (700). `mcp.<name>.headers` is a secret in the key table, so `troupe config
  --explain` masks a value as it masks a key, with the `{env:VAR}` it came from beside
  it. `Server`'s `inspect` leaves the headers out, and `Troupe.Session.MCP`'s
  `format_status/1` prints a server's `env` and `headers` by name, for a crash report
  and `:sys.get_status/1`. An import's warnings name the variable, never the value.
- **A workspace's server says it sends them.** A header can read the person's own
  variable and send it to a URL a cloned repository chose, so the trust question (700)
  names the headers ("notes (https://…, sending the headers X-Api-Key, X-Team)"), and
  the fingerprint takes them as read, as it takes `env`: changed headers ask again, and
  so does a variable whose value changed, as an `env` value's does.
- **Import carries them.** Claude Code's, Cursor's and VS Code's `headers`, with
  `${VAR}` read as `{env:VAR}` and a VS Code `${input:…}` skipping the server, as
  before. opencode's `mcp` block is read too: `type: local` with a `command` list and an
  `environment`, `type: remote` with `url` and `headers`, `enabled: false` as off; its
  `timeout` (how long the tool listing is waited for, not a call) and `oauth: false` are
  not read, and a `{file:…}` skips the server, since only opencode reads one. It is read
  from the file's text, so `Troupe.Config.OpenCode` is not touched. Claude Code's
  `headersHelper`, a command that prints headers, is not run, and the import says so.
- **A copy never copies a value written out.** `mcp.add` with `from` and no `link`
  (`Import.parse(text, copy: true)`) writes a header whose value reads no variable as
  `{env:<SERVER>_<HEADER>}`, upper case with `_` (a leading digit gets `MCP_`), a
  `Bearer `, `Basic ` or `Token ` kept in front so the variable holds the credential
  alone, and a warning names the variable and says the value is in the file it came
  from. Every such header, not only one named like a credential: an importer cannot
  tell from `X-Honeycomb-Team` that it is a key, and a header on an MCP server is nearly
  always how it is keyed; a value that is not a secret is one edit to write back. One
  rule, the one 741 gives for `mcp.json`: it is linked, copied and committed, and a
  credential does not belong in it. A link reads the other tool's file where it is,
  where the value already was, and writes nothing. An `env` value is copied as 700
  copies it, since one is as often a log level as a key; whether a literal one should
  follow this rule is left for its own issue.
- **No keychain.** The maintainer's answer to #60's one open question: a header's
  secret stays in the person's environment, as `{env:VAR}`, and an OAuth server's tokens
  in `<state>/mcp-oauth.json` (741). For the token store's reasons: the daemon has no
  keychain in this build (the model key is in `config.yaml` for the same reason), and it
  is the process that sends the header, so a keychain only the desktop app could read
  would leave a terminal-only person with nothing. `{env:VAR}` already keeps a secret
  out of every file Troupe writes, reads the same on every platform and in CI, and is
  what the other tools' files already say (`${VAR}`), so an import needs no second
  place to put one. If the daemon gains a keychain for its own model key, headers and
  tokens move with it.
- **Not this slice.** A bundle's servers on a pod carry their one credential and no
  `headers` (`Bundle.mcp_server_configs/1` sends none). The TUI's `/mcp` page and the
  desktop app's panel draw a server's URL or command and no other field, so they show no
  headers either; `mcp.list` carries the names for when they do.
- **Proof:** `Troupe.MCP.ClientHeadersTest` (troupe_protocol, against
  `test/support/fake_mcp.exs`, which now reports every header of every request: the
  headers on `initialize`, `notifications/initialized`, the listing, a call and the
  `DELETE`, failed on the tip; the credential winning an `Authorization`; nothing in
  `inspect`), `Troupe.MCP.ImportTest` (Claude Code's headers kept, failed on the tip;
  Cursor's, VS Code's, opencode's block, `headersHelper`, `{file:…}`, and a copy's
  `{env:…}` and warnings with no value in them), `Troupe.MCP.LocalTest` (read from the
  environment, unset refused, never written back, the fingerprint; the refused names and
  values; an import copying and a link reading as written), `Troupe.Config.LayersTest`
  (`config.yaml`'s headers read and refused, `--explain` masking them in text and JSON),
  `Troupe.MCPHandshakeTest` (a local session sends them on every request and the
  `DELETE`, its status holds no value, and a workspace's question names them) and
  `Troupe.Gateway.LocalSourcesTest` (`mcp.add` and `mcp.list` over the daemon's socket,
  names only).
