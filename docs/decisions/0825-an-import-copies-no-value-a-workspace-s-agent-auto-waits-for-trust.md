---
number: 825
title: "An MCP import copies no value written out, `env` as headers; a workspace's agent `auto` applies only once it is trusted; Codex's `[mcp_servers]` import"
date: 2026-10-09
status: accepted
issue: 516
supersedes: [820]
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/config/toml.ex
  - apps/troupe_core/lib/troupe/config/trust.ex
  - apps/troupe_core/lib/troupe/mcp/import.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/test/troupe/agent/workspace_permissions_test.exs
  - apps/troupe_core/test/troupe/config/toml_test.exs
  - apps/troupe_core/test/troupe/mcp/import_test.exs
  - apps/troupe_core/test/troupe/mcp/local_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/agents_trust_test.exs
  - apps/troupe_gateway/test/troupe/gateway/local_sources_test.exs
  - clients/tui/README.md
  - docs/user/configuration.md
symbols:
  - Troupe.Agent.Definition.permission/3
  - Troupe.Agent.Definition.trust/3
  - Troupe.Agent.Definitions.trust/3
  - Troupe.MCP.Import.parse/2
  - Troupe.MCP.Import.codex_user_path/0
  - Troupe.Config.TOML
gist: "A copy writes env and headers as {env:<SERVER>_<NAME>}; .troupe/agents auto is the tool's default until trusted, at run time; Codex TOML"
---

Issue #516, slice 5 ("MCP, permissions and secrets"), which folds in #508 and #511 and
adds Codex. Three changes, one theme: what another tool's or a repository's files say
does not decide by itself that a secret is written into a file Troupe keeps, or that a
tool runs without a question.

- **`env` follows the copy rule (#508).** Decision 820 wrote a header's literal value as
  `{env:<SERVER>_<HEADER>}` on a copy and left `env` as 700 had it, "since one is as
  often a log level as a key". That part of 820 is superseded: a copy (`mcp.add` with
  `from` and no `link`, `/mcp import`, `Import.parse(text, copy: true)`) now writes every
  `env` value that reads no variable as `{env:<SERVER>_<NAME>}` (upper case, `_` for
  anything else, `MCP_` before a leading digit; `github`'s `GITHUB_TOKEN` is
  `{env:GITHUB_GITHUB_TOKEN}`), a `Bearer `/`Basic `/`Token ` kept in front, and a
  warning names the variable and says the value is in the file it came from. One rule for
  both, as 820 argued for headers: an importer cannot tell a token from a log level, and
  the file it writes is linked, copied and committed. The server prefix rather than the
  name alone (`{env:GITHUB_TOKEN}`) because two servers' `API_KEY` must not read one
  variable. A number or a boolean is a value written out too. An empty value and one
  that already reads the environment are kept. A link writes nothing and reads the other
  tool's file where the value already was.
- **A workspace's agent `auto` waits for trust (#511).** A `.troupe/agents/*.md` arrives
  with a clone, and `permissions: {shell: auto}` in it made the shell run unasked in any
  workspace. Now an `auto` in a `:project` definition applies only when the workspace is
  trusted (`trusted_workspaces`, 686); until then `Definition.permission/3` answers the
  tool's own default, so `shell`, `write_file`, `edit_file` and `web_fetch` ask, and a
  tool that runs unasked anyway still does. Its `ask` and `deny` apply regardless, since
  they narrow. The person's own `<config>/agents/`, a bundle's and the built-ins are not
  the workspace's and are untouched. Gated **at run time, where a session reads the
  permission**, not when a file is written: `permission/3` is the one function every
  reader goes through (the offered tool list, `Tools.authorize/3`, `Tools.run_task/4`,
  the `!cmd` gate), so a hand-written file and anything onboarding writes later (#516
  slices 3 and 4 map Claude Code's and opencode's `allow` to `auto`) are covered alike.
  The definition carries `trusted?`, **false unless someone vouches**: the session stamps
  its snapshot once at start (`Definitions.trust/3` in `Session.build_opts/1`, trusted
  when the session is local and the workspace is on `trusted_workspaces`, as the
  session's MCP servers are judged), so any other loader that forgets is safe rather
  than open. A pod's session trusts no workspace's agents, as it reads no gated key from
  a project's file (686). `agents.list` stamps the same way (a daemon by the user's file,
  a worker never) and carries `notes`, `[{"key", "reason"}]`, the shape the closed #510
  branch gave them: one `permissions` note naming what is held, that it applies once the
  workspace is trusted and the command that trusts it. `troupe config trust` and
  `untrust` say so in their answers. Trust is read when the session starts, as the gated
  config keys are, so a workspace trusted mid-session applies to the next one.
  `definitions.ex` gains that one function and nothing else (slice 7 changes its layer
  merge).
- **Codex (`[mcp_servers.<name>]`).** A Codex `config.toml` imports and links as the
  others' JSON does. Its keys map onto the entry: `command`, `args`, `env`, `cwd`; `url`
  with `http_headers`, `env_http_headers` (a header read from the variable it names) and
  `bearer_token_env_var` (an `Authorization: Bearer {env:VAR}`); `enabled = false` is
  `disabled`; `tool_timeout_sec` is `timeout_ms`. `env_vars` is not needed, since a
  server the daemon starts has its environment; `startup_timeout_sec` and `required` have
  nothing to map to. What the person would miss is named in the import's warnings:
  `http_headers_helper` (a command, not run, as Claude Code's `headersHelper`),
  `enabled_tools`/`disabled_tools` (every tool is offered, each asks), `tools` and
  `default_tools_approval_mode` (each asks), `auth`/`scopes`/`oauth_resource` (a sign-in
  is `oauth` with a `client_id`). A variable name that is not one refuses the server,
  naming the key. **Which layer:** sources disagree on whether Codex's project file or
  the user's wins; Troupe does not inherit either answer, since once imported its own
  layers decide (the workspace's `.troupe/mcp.json` over the user's, 700). A project's
  `.codex/config.toml` goes into whichever layer the person names; the person's own
  `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) only into theirs, copied or
  linked, because a workspace's file goes wherever the repository goes and would carry
  their servers, or a link into their home, with it.
- **A narrow reader, not a dependency.** `Troupe.Config.TOML` reads TOML 1.0 into maps:
  tables, arrays of tables, bare, quoted and dotted keys, the four kinds of string with
  their escapes, integers in four bases, floats, booleans, arrays over lines with
  comments, inline tables; a date, a time, `inf` and `nan` are kept as their text. It is
  about 340 lines and reads whole documents, so a Codex file's other tables (profiles,
  model providers, multi-line instructions) never confuse where an `[mcp_servers]` table
  begins. Not a dependency, because one file format read at import time is not worth a
  new package in the daemon's release, its licence review (`scripts/licences.exs`) and
  the supply chain that comes with it, and because the reader is lenient where an
  importer should be (a key given twice is the later one; the owning tool refused such a
  file already). If Troupe ever writes TOML or reads it on a hot path, a maintained
  parser is the better choice and this module goes.
- **Not this slice.** Onboarding's writer (slice 3) and the agent importer (slice 4) call
  `Import.parse(..., copy: true)` and leave `auto` to this gate; the TUI's `/mcp` page and
  the desktop app's panel still show no `env` or header names (D97), and the desktop
  app's import hint does not name Codex. `agents.list` lists primaries only, so a
  subagent's held `auto` has no note anywhere a client shows.
- **Proof:** `Troupe.MCP.LocalTest` (an import copying a literal `env` as its variable,
  the written file grepped for the value, a link reading it as written: failed on the
  tip; a project's Codex file copied, a linked one read as TOML, the person's own refused
  for a workspace), `Troupe.MCP.ImportTest` (the `env` rule with numbers, booleans,
  `Bearer`, references and empties; Codex's tables, headers, timeouts, skips and
  warnings), `Troupe.Config.TOMLTest`, `Troupe.Agent.WorkspacePermissionsTest` (a
  `.troupe/agents` fixture with `shell: auto` in an untrusted workspace asks: failed on
  the tip, where the shell ran; trusted, it runs unasked; the person's own and the
  built-ins keep their `auto`; the note), `Troupe.Gateway.LocalSourcesTest` (`mcp.add`
  over the daemon's socket into both layers, no value in the answer or the files) and
  `Troupe.Gateway.AgentsTrustTest` (`agents.list`'s note until trusted and none after, and
  a pod's always).
