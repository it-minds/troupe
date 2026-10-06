---
number: 700
title: A person's own MCP servers and skills live in two layers beside `config.yaml`, import from the files other tools keep, and a workspace's servers run only once somebody attached has said so
date: 2026-09-26
status: accepted
issue: 60
paths:
  - apps/troupe_core/lib/troupe/commands/local.ex
  - apps/troupe_core/lib/troupe/mcp/import.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/mcp/trust.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/lib/troupe/skills.ex
  - apps/troupe_core/lib/troupe/skills/local.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/test/troupe/mcp/import_test.exs
  - apps/troupe_core/test/troupe/mcp/local_test.exs
  - apps/troupe_core/test/troupe/mcp_layers_test.exs
  - apps/troupe_core/test/troupe/mcp_local_test.exs
  - apps/troupe_core/test/troupe/skills/local_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_gateway/test/troupe/gateway/local_sources_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/apps/desktop/src/views/Servers.tsx
  - clients/gui/apps/desktop/test/servers-panel.test.tsx
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/test/local-sources.test.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/mcp_page_test.exs
gist: A person's own MCP servers and skills live in two layers beside `config.yaml`, import from the files other tools keep, and a workspace's servers…
---

Issue #60, the local half. What was there: `mcp:`
in `config.yaml` (654), read from a project's file only in a trusted workspace
(686), and skills read from the pinned bundle alone. What a person has is a
`.mcp.json` from Claude Code, Cursor, Claude Desktop or VS Code and a
`~/.claude/skills`, and bringing them in meant retyping them into YAML.
- **Layers.** `<config>/mcp.json` and `<config>/skills/` for the user,
  `.troupe/mcp.json` and `.troupe/skills/` for the workspace: the `mcpServers`
  shape every other tool reads and writes, plus an `include` list that reads
  another file in place — a *link*; `skills.json` does the same for directories of
  skills. They stack over `config.yaml`'s `mcp:` as the config files stack (686):
  merged by name, key by key, the workspace's over the user's, `null` removing and a
  list replacing, so `{"disabled": true}` alone turns a lower layer's server off.
  Each server and skill carries its layer and its file, since that is what a person
  needs to know to change it (`Troupe.MCP.Local`, `Troupe.Skills.Local`).
- **Import.** `Troupe.MCP.Import` reads the four shapes: `${VAR}` and `${env:VAR}`
  become `{env:VAR}`, which the loader refuses when unset instead of sending an
  empty string; a VS Code `${input:…}` skips that server and says so, since only VS
  Code could fill it in; `headers` are dropped with a warning, a credential this
  slice does not carry. `mcp.add` with `from` copies, or links; `skills.add` copies
  a directory of `SKILL.md`s or one skill's directory, or links it.
- **Trust.** A `.troupe/mcp.json` arrives with a clone. Its servers start only after
  the session's question, through `Troupe.Session.Questions` under
  `mcp-trust-<hash>`, so any client that answers an `ask_user` answers this; `deny`
  is the first option, so a runner with nobody to ask runs nothing. `allow` is
  remembered in `<state>/mcp-trust.json` per checkout (`Troupe.MCP.Trust`), beside a
  fingerprint of the command, its arguments, environment, directory or URL, so a
  changed command is a new question and a re-ordered file is not; `once` runs them
  for the session; `deny` leaves them stopped until the next session or a reload.
  A workspace on `trusted_workspaces` is not asked, since trusting it already lets
  its `config.yaml` name what runs; the user's layer asks nothing, since the person
  wrote it. A pod session reads no layer at all, and `managed_mcp_servers_only`
  starts nothing local and says so in each server's status.
- **Skills.** A bundle's skills stay gated by the profile's `skills:` list and the
  team's entitlements; a person's own are offered to every agent of the session,
  because the person put them there and a skill nobody can call is not one. They
  are read beside the workspace wherever the session runs, as `.troupe/agents/` is.
  A local skill's files are listed by their path, and the user's directory and every
  linked root are read roots of the session.
- **Protocol.** `mcp.list`, `mcp.add`, `mcp.remove`, `mcp.check` and `skills.list`,
  `skills.add`, `skills.remove`, the daemon's only like `config.*`; `mcp.status`
  gains `layer` and `source`. `mcp.check` on a session's server reads its files
  again and starts what they say now — reconnect, enable and disable in one verb —
  and on a server not in a session runs it once and stops it. `mcp.list` with a
  `session_id` joins the live state onto the listing, so one call fills a page. Env
  values never go over the wire: `mcp.list` and `mcp.add` answer with the names.
- **Out of this slice**, and said in the pull request: streamable HTTP and SSE with
  OAuth for remote servers, and keychain storage for their tokens. A `url` server
  stays the one-shot HTTP client 654 gave it.
- **Proof:** `Troupe.MCP.ImportTest` (the four shapes, placeholders, skips),
  `Troupe.MCP.LocalTest` (layering, links, merging, writes, the trust store),
  `Troupe.Skills.LocalTest` (both layers, copy and link, the tool and the prompt),
  `Troupe.MCPLocalTest` (the question and each answer, a trusted workspace,
  `managed_mcp_servers_only`, reload), `Troupe.MCPLayersTest` (the user's layer and
  the read roots), `Troupe.Gateway.LocalSourcesTest` (the seven methods over the
  daemon's socket, and none without the daemon), the TUI's `Troupe.MCPPageTest` and
  the GUI's `local-sources.test.ts` and `servers-panel.test.tsx`.
