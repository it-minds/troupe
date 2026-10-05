---
number: 654
title: A workspace may name its own MCP servers, and a stdio one runs under the reaper like everything else
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/mcp/stdio.ex
  - apps/troupe_core/lib/troupe/reaper.ex
  - apps/troupe_core/lib/troupe/registry.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/test/troupe/mcp_local_test.exs
  - apps/troupe_core/test/troupe/reaper_test.exs
  - clients/tui/lib/troupe/client/daemon.ex
gist: A workspace may name its own MCP servers, and a stdio one runs under the reaper like everything else
---

A pod's servers come from its bundle; a laptop has none, so
`.troupe/config.yaml` may say `mcp: {name: {command, args, env, cd}}` or `{url}`,
and `Troupe.Session.MCP` starts them with the session: a `command` server is a
subprocess speaking newline-delimited JSON-RPC on its standard streams
(`Troupe.MCP.Stdio`) for as long as the session lives, a `url` server is the same
one-shot client the pod uses, discovered once. Both kinds' tools are
`mcp.<server>.<tool>` and go through the same allowlist, permission map and approval
gate as a built-in; `ask` unless the server's entry says `permission: auto`. The
reaper forwards the owner's bytes in a mode of its own (`TROUPE_REAPER_STDIO`), Unix
only: stdin is pumped into the child through a pipe, stdout and stderr are
inherited, and EOF on the owner's side closes the child's stdin — which is how an
MCP server is told to exit — with the tree taken down after the grace if it has not. On Windows the server runs as a plain port and
is trusted to honour that same contract, which is written down here rather than
pretended otherwise. `mcp.status {session_id}` is what a client's `/mcp` page shows.
