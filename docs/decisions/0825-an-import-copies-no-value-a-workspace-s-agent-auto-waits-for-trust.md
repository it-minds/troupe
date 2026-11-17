---
number: 825
title: "An MCP import copies no value written out, `env` as headers; a workspace's agent `auto` applies only once it is trusted; Codex's `[mcp_servers]` import"
date: 2026-10-09
status: accepted
issue: 516
supersedes: [820]
paths:
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/config/toml.ex
  - apps/troupe_core/lib/troupe/config/trust.ex
  - apps/troupe_core/lib/troupe/mcp/import.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
symbols:
  - Troupe.Agent.Definition.permission/3
  - Troupe.Agent.Definition.trust/3
  - Troupe.Agent.Definitions.trust/3
  - Troupe.MCP.Import.parse/2
  - Troupe.MCP.Import.codex_user_path/0
  - Troupe.Config.TOML
gist: "A copy writes env and headers as {env:<SERVER>_<NAME>}; .troupe/agents auto is the tool's default until trusted, at run time; Codex TOML"
---

Three changes, one theme: what another tool's or a repository's files say does not decide
by itself that a secret is written into a file Troupe keeps, or that a tool runs without a
question.

- **`env` follows the copy rule (#508).** That part of 820 is superseded: a copy
  (`mcp.add` with `from` and no `link`, `/mcp import`, `Import.parse(text, copy: true)`)
  now writes every `env` value that reads no variable as `{env:<SERVER>_<NAME>}` (upper
  case, `_` for anything else, `MCP_` before a leading digit; `github`'s `GITHUB_TOKEN` is
  `{env:GITHUB_GITHUB_TOKEN}`), a `Bearer `/`Basic `/`Token ` kept in front, and a warning
  names the variable and says the value is in the file it came from. One rule for both, as
  820 argued for headers: an importer cannot tell a token from a log level, and the file
  it writes is linked, copied and committed. A link writes nothing and reads the other
  tool's file where the value already was.
- **A workspace's agent `auto` waits for trust (#511).** A `.troupe/agents/*.md` arrives
  with a clone, and `permissions: {shell: auto}` in it made the shell run unasked in any
  workspace. Now an `auto` in a `:project` definition applies only when the workspace is
  trusted (`trusted_workspaces`, 686); until then `Definition.permission/3` answers the
  tool's own default, so `shell`, `write_file`, `edit_file` and `web_fetch` ask, and a
  tool that runs unasked anyway still does. Its `ask` and `deny` apply regardless, since
  they narrow. Gated **at run time, where a session reads the permission**, not when a
  file is written: `permission/3` is the one function every reader goes through (the
  offered tool list, `Tools.authorize/3`, `Tools.run_task/4`, the `!cmd` gate), so a
  hand-written file and anything onboarding writes later (#516 slices 3 and 4 map Claude
  Code's and opencode's `allow` to `auto`) are covered alike. The definition carries
  `trusted?`, **false unless someone vouches**: the session stamps its snapshot once at
  start (`Definitions.trust/3` in `Session.build_opts/1`, trusted when the session is
  local and the workspace is on `trusted_workspaces`, as the session's MCP servers are
  judged), so any other loader that forgets is safe rather than open. A pod's session
  trusts no workspace's agents, as it reads no gated key from a project's file (686).
- **Codex (`[mcp_servers.<name>]`).** **Which layer:** sources disagree on whether Codex's
  project file or the user's wins; Troupe does not inherit either answer, since once
  imported its own layers decide (the workspace's `.troupe/mcp.json` over the user's,
  700). A project's `.codex/config.toml` goes into whichever layer the person names; the
  person's own `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) only into theirs,
  copied or linked, because a workspace's file goes wherever the repository goes and would
  carry their servers, or a link into their home, with it.
- **A narrow reader, not a dependency.** Not a dependency, because one file format read at
  import time is not worth a new package in the daemon's release, its licence review
  (`scripts/licences.exs`) and the supply chain that comes with it, and because the reader
  is lenient where an importer should be (a key given twice is the later one; the owning
  tool refused such a file already).
