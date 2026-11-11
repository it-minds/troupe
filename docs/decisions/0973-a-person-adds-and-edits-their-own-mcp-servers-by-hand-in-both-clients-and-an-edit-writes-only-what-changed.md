---
number: 973
title: "A person adds and edits their own MCP servers by hand in both clients, on the desktop app's Tools and skills and with the TUI's /mcp add and /mcp try; an edit writes only what changed, values never come back, and a local session's screen says how each server stands there"
date: 2026-11-10
status: accepted
paths:
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/gui/packages/client/src/servers.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/apps/desktop/src/views/ConnectScreen.tsx
  - clients/gui/apps/desktop/src/views/SessionServers.tsx
  - docs/user/mcp.md
symbols:
  - Troupe.UI.TUI.Server.parse_server/1
gist: "Add and edit a server without a file to import: a drawer in the desktop app, /mcp add and /mcp try in the TUI; an edit is the difference, merged as RFC 7396; no value comes back"
---

Extends 700 (a person's own servers live in two layers of `mcp.json`, imported from
other tools' files), 741 (a server that signs the person in is signed in to by the
daemon) and 820 (headers are literal or `{env:VAR}`, shown by name only, and there is no
keychain). Until this, a server reached either client only by importing or linking
another tool's file, or by writing `mcp.json` by hand: neither client could say
"this command" or "this URL, signing me in" by itself, and a person who uses only the
desktop app had no way to bring a tool of their own that no other tool already had.

- **Both clients write one server, through the method that was there.** `mcp.add` with a
  `name` and a `server` already merged an entry onto the layer's file; the desktop app's
  drawer (Tools and skills → **Set one up by hand**, **Edit**) and the TUI's `/mcp add
  <name> …` send it. `/mcp try` and the drawer's **Try it first** send the same entry to
  `mcp.check`, which runs it once and keeps nothing. No method is added; the TUI and the desktop app reach the same
  daemon calls, so neither has a server the other cannot write.
- **An edit is what changed.** The form sends only the keys that differ from the server
  as listed, `null` for what was taken out, and the daemon merges it as the layers merge
  (RFC 7396). So an entry's keys the form does not show survive an edit, and a server from
  `config.yaml` or a linked file is changed by writing the difference over it in the
  person's own `mcp.json`, never by copying it whole. A command or a URL switches
  transport and clears the other's keys.
- **No value comes back, and none is shown.** Decision 820 holds: `mcp.list` names a
  server's variables and headers and never their values. The form shows one as kept,
  and keeps it unless it is given a new value or its line is taken out. Where a value
  typed into either client goes, the keychain, is Decision 974.
- **`mcp.list` says everything an entry has but its values**: `stores`, `files`,
  `timeout_ms`, and the sign-in's `redirect_uri` and `resource: false` besides its client
  id, scopes and issuer, so a form starts from what the file says. The TUI's `/mcp` page
  shows the same, so neither client knows more about a server than the other.
- **Tools and skills is a screen of its own.** The desktop app's servers and skills move
  from This computer to a **Tools and skills** entry in the rail, and the palette's `/mcp`
  and `/skills` open it, as the TUI's open its page. The harness's sign-in hints name it.
  Each server is a row that says in words how it stands and offers the one fix for it;
  servers come in from another app's file (followed, the suggested way, or copied) or by
  hand, each in a drawer.
- **A local session's screen says how each server stands there.** A line under the
  session's head in the desktop app, from `mcp.list` with the session's id: Start for a
  server written after the session began, Restart to read its file again, and Sign in.
  The TUI's `/mcp` page already did this with `c` and `s`.
- **The workspace's question is unchanged.** A server written to a workspace's
  `.troupe/mcp.json` starts in a session only once someone answers it there (Decision
  830), however it was written.
