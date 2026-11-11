---
number: 974
title: "A key a person gives one of their own MCP servers is kept in the operating system's keychain and the entry holds a {secret:…} reference to it; a workspace's server reads only its own until trusted; a check and a session say what each tool is; the daemon finds other tools' folders of skills"
date: 2026-11-11
status: accepted
supersedes: [820]
paths:
  - apps/troupe_core/lib/troupe/mcp/secrets.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_core/lib/troupe/mcp/stdio.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/lib/troupe/skills/local.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/gui/packages/client/src/servers.ts
  - clients/gui/apps/desktop/src/views/ConnectScreen.tsx
  - docs/user/mcp.md
symbols:
  - Troupe.MCP.Secrets.ref/3
  - Troupe.MCP.Tool.said/1
  - Troupe.Skills.Local.discover/2
gist: "Pasted keys go to the OS keychain as {secret:<server>/<key>} (mcp.secret), never the file; untrusted workspace servers read only their own prefix; mcp.list/check carry missing, secrets and each tool's title/summary/readOnlyHint; skills.discover"
---

Supersedes the part of 820 that said Troupe keeps no keychain for a server's headers and
variables. Under 820 a key was written out in `mcp.json` or read from the environment
with `{env:VAR}`. The first puts a credential in a file people link, copy and commit; the
second asks a person who uses only the desktop app to set a variable where the daemon
will see it, which most cannot. Decision 973 gave both clients a form for a server, and a
form a person pastes a key into must have somewhere safe to put it.

- **The value goes to the operating system's keychain; the entry gets a reference.**
  `mcp.secret` keeps it with `Troupe.Keyring` (Windows' Credential Manager, the macOS
  keychain, the Secret Service), which the daemon already uses for its sign-in for
  steering, under `mcp/<server>/<key>`, base64-encoded since each platform's tool takes it
  through a shell. The variable or header is written `{secret:<server>/<key>}` and read
  when the server starts, as `{env:VAR}` is. A computer with no keychain Troupe can use is
  told so, and nothing is written: the key is then an `{env:VAR}`, as before. Removing a
  server forgets the secrets kept for it.
- **`{env:VAR}` stays.** A value that reads the environment is still written as it is; a
  client sends a typed value to the keychain unless it reads the environment.
- **A workspace's server reads only its own secrets until the workspace is trusted.** A
  cloned repository's `.troupe/mcp.json` could otherwise name `{secret:github/TOKEN}` and
  send the person's own token to an address the repository chose. A secret set for a
  workspace's server is kept under that workspace's prefix (`ws-<16 hex of its real
  path>/`), and until the workspace is on `trusted_workspaces` a workspace-layer server
  that names any other reference is refused, saying why. The workspace's start question
  (Decision 830) still comes first.
- **The listing says which keys want a value.** `mcp.list` carries `secrets`, the keys
  the keychain keeps, and `missing`, the keys whose `{env:VAR}` is unset or whose
  `{secret:…}` is not there, so a client asks for that one by name rather than reading the
  refusal's words. The value never comes back.
- **What each tool is, in the server's words.** A check, a session's status and
  `mcp.tools` carry each tool's `title`, its own description as `summary`, and its
  `readOnlyHint` as `read_only`, for a person to read before letting an agent use it. A
  hint is the server's word: nothing is decided on it, and the permission a tool asks with
  is what it was.
- **The daemon finds the folders of skills other tools keep.** `skills.discover` lists
  Claude Code's, Codex's and opencode's skills folders and a project's `.claude/skills`
  that are there, each with its skills and whether a layer has it already, for a client to
  offer bringing it in with `skills.add`. It reads and writes nothing else. Finding other
  tools' files of servers is not part of this: a server is still brought in from a file
  named.
- **Both clients do all of it.** The desktop app asks for a missing secret in the server's
  row and takes secrets in its drawer; the TUI's `/mcp` page asks with `p` or `/mcp secret`,
  drawing what is typed as dots, since a command line is drawn as typed. Both show the
  tools' titles and marks and the folders of skills to bring in.
