---
number: 830
title: "A workspace's MCP server set to `permission: auto` runs its tools unasked only once the workspace is trusted; the start question grants starting it and says so; the workspace's layer reads nothing from outside the repository until trusted; a linked `opencode.json` gives its servers"
date: 2026-10-10
status: accepted
issue: 522
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/config/trust.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/troupe/config/trust_test.exs
  - apps/troupe_core/test/troupe/mcp/local_test.exs
  - apps/troupe_core/test/troupe/mcp_layers_test.exs
  - apps/troupe_core/test/troupe/mcp_local_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/test/troupe/gateway/local_sources_test.exs
  - docs/user/configuration.md
symbols:
  - Troupe.MCP.Local.waits_for_trust?/1
  - Troupe.MCP.Local.held_reason/2
  - Troupe.MCP.Local.resolve/2
  - Troupe.Session.MCP
gist: "Workspace MCP auto and includes from outside the repo wait for trust (held at session start/resolve); allow grants starting only; opencode.json links"
---

Issue #522, found while gating a workspace agent's `auto` on trust (Decision 825), and
the first item of D100. Decision 825 is the pattern; this applies it to the other place a
repository's file could let a tool run unasked.

- **What was wrong.** A `.troupe/mcp.json` arrives with a clone and may say
  `"permission": "auto"` on a server. Its servers start only after the session's question
  (Decision 700), but once that was answered `allow` (or `once`) every tool of the server
  ran without asking: the question was about starting a command, and the answer granted
  its tools' calls as well. On the tip, `Troupe.MCPLocalTest`'s fixture (an untrusted
  workspace, its stub server at `auto`, the start allowed) ran the agent's
  `mcp.stub.greet` with no `approval_requested` at all.
- **The rule.** A server the workspace's layer names, in `.troupe/mcp.json` or in a file
  that file links (`include`), and that says `permission: auto`, has its `auto` apply only
  when the workspace is trusted (`trusted_workspaces`, Decision 686). Until then its tools
  are `ask`, whatever the start's answer; the start's question is about starting.
  The person's own `<config>/mcp.json` (and what it links, wherever that is) and
  `config.yaml`'s `mcp:` (read from a project's file only when it is trusted, 686) keep
  what they say. A pod trusts no workspace (as 825 has it for agents), and reads none of
  these layers anyway (700).
- **Which entry is the workspace's.** The layers merge by name (700) and a merged entry
  carries the highest layer that names it. An entry the workspace's file changes over one
  of the person's own (`{"shared": {"command": "elsewhere"}}`) is the workspace's: what
  would run unasked is then what the workspace says, so the person's `auto` beneath it is
  held too. A workspace that only turns the person's server off or on holds it as well;
  narrower than needed, and a person who wants their `auto` back moves the entry or trusts
  the workspace. `Troupe.MCP.Local.waits_for_trust?/1` is the one test.
- **Gated where a session starts the server, at run time.** `Troupe.Session.MCP`'s
  `start/2` is where a server's `permission` becomes its tools' default permission, for a
  stdio server (`Troupe.MCP.Stdio`) and a URL server (`Troupe.MCP.Server`) alike, and the
  path a `reload` and a finished sign-in take too; it starts a held server with `ask`. Not
  in `Troupe.MCP.Local.resolve/2`, which `mcp.list`, the trust store's fingerprint and
  `mcp.check` read and which should say what the file says; not when a file is written,
  for 825's reason: a hand-written `.troupe/mcp.json`, a copied import (which keeps the
  other file's `auto`, the issue's second sentence) and whatever onboarding writes are
  covered alike. Trust is what `Troupe.Session` passed at start (the user file's list, as
  the session's config read it), so a workspace trusted mid-session applies to the next
  session, as 825's agents and 686's gated keys do.
- **The question says what it grants.** "This workspace's .troupe/mcp.json names MCP
  servers to start on this machine: … Start them?", the options `start none of them`,
  `start them for this session only`, `start them, and remember it for this workspace`;
  "run" said more than the answer gives. Where a listed server is set to `auto`, the
  question says so before asking: "stub is set to permission: auto, which applies once this
  workspace is trusted (troupe config trust <path>); until then its tools ask before each
  call." Only an untrusted workspace is asked at all (700), so that sentence is true
  whenever it is shown. The labels and their order (`deny` first) are 700's.
- **`mcp.list` says why, additively.** Each server gains `notes`, `[{"key", "reason"}]`,
  the shape `agents.list` gave a held agent (825): one `permission` note, the same sentence,
  on a workspace server set to `auto` while the workspace is not trusted (read from the
  user file when the list is asked for, as `agents.list` does); `[]` otherwise.
  `permission` stays what the entry says, and `trust` stays `trusted` or `pending` for the
  start, so no client reads either differently. The TUI's `/mcp` page and the desktop app do
  not show `notes` yet. `troupe config trust` and `untrust` name the servers beside the
  agents in their answers.
- **A workspace's layer reads nothing from outside the repository until it is trusted.**
  Found beside this by the #519 fixer (Decision 829): a `.troupe/mcp.json` could
  `include` the person's own file (`~/.claude.json`, `<config>/mcp.json`) and so offer
  their servers, their environment with them, under the workspace's layer, asked about as
  the repository's at best. Now the workspace's layer is held to the repository
  (`Troupe.Instructions.repository_root/1`, the directory with `.git`, else the workspace),
  by where each file really is, links followed, as 829 holds a `skills.json`'s include:
  an include from outside, a link inside that points out, and a `.troupe/mcp.json` that is
  itself a link out are not read until the workspace is trusted, and each is named in the
  warnings, "… includes ~/.claude.json, outside the repository: not read until this
  workspace is trusted (troupe config trust <path>)", which `mcp.list` carries and the
  session logs. Inside the repository an include is read as before; once trusted, anything
  is, since trusting a workspace is how a person says its files may name what runs (686).
  The person's own layer has no edge. In the warnings rather than a new field: they are
  where `mcp.list` already says a linked file is missing or malformed, and no server comes
  of it, so there is no entry to hang a note on. `Troupe.MCP.Local.resolve/2` takes
  `trusted: true`; anything else is not, so a caller that forgets is held. The session
  passes what it judged at start; `mcp.list`, `mcp.check`, `mcp.sign_in`, `mcp.tools` and
  `mcp.call` pass the user's file's word, so a held server is `not_found` there too. The
  three existing tests that link a file from elsewhere into a workspace's layer
  (Decisions 700, 820 and 825: a link reads the other file as written) now resolve with
  `trusted: true`, which is what they test.
- **D100: a linked `opencode.json` gives its servers.** `Troupe.MCP.Local`'s reader took a
  layer file's servers from `mcpServers`, `servers` and `mcp_servers`, so a file linked
  with `include` read as empty when it was opencode's, whose servers are under `mcp`, while
  a copy of it worked. It now takes `mcp` too and hands it to `Troupe.MCP.Import.from_map/2`,
  which reads opencode's entries as an import does (a `command` list, `environment`,
  `enabled: false` as off) and already tells that key from a bare map with one server
  named `mcp`.
- **Not this decision.** An import that copies an `auto` into the person's own layer keeps
  it without a word, since the person chose that file; a warning naming it is a follow-up.
  `mcp.call` and `mcp.tools` (Decision 748) call a person's server outside any session and
  take no permission; a pod session offered those tools asks, as 748 has it.
- **Proof:** `Troupe.MCPLocalTest` (an untrusted workspace's `auto` stub, its start
  allowed: the tool's default is `ask` and the agent's call raises `approval_requested`,
  both failed on the tip, where the call ran; the same workspace trusted: not asked to start
  it, and the call runs unasked; the question's wording, failed on the tip; a pod session
  reads none of it), `Troupe.MCPLayersTest` (the person's own server keeps `auto` in an
  untrusted workspace), `Troupe.MCP.LocalTest` (`waits_for_trust?/1` on a workspace entry,
  a file the workspace links and a workspace's change over the person's own, and not on
  the person's own or `config.yaml`'s; a linked `opencode.json` resolving to its servers
  and unlinking naming them, failed on the tip with none; a workspace's include of the
  person's own file held and named until `trusted: true`, the person's own layer reading
  it, the repository rather than the workspace as the edge, a link inside pointing out
  held, and a `.troupe/mcp.json` that is a link out held), `Troupe.Gateway.LocalSourcesTest`
  (`mcp.list`'s `permission` note on the workspace's `auto` server only, gone once the user
  file trusts the workspace: failed on the tip, where there was no `notes`; an include of
  the person's own file listed in `warnings` with the command, `mcp.check` of its server
  `not_found`, and listed once the user's file trusts the workspace), `Troupe.MCPLocalTest`
  (an untrusted session reads no server from such an include and asks nothing; a trusted
  one starts it) and `Troupe.Config.TrustTest` (the answers name the servers).
