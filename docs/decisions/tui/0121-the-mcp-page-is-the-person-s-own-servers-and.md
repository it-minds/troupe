---
number: 121
title: The `/mcp` page is the person's own servers and skills, from the daemon's layers, with the verbs to bring them in; it never holds a path of its own
date: 2026-09-26
status: accepted
issue: 60
paths:
  - clients/tui/lib/troupe/client.ex
  - clients/tui/test/troupe/mcp_page_test.exs
gist: The `/mcp` page is the person's own servers and skills, from the daemon's layers, with the verbs to bring them in; it never holds a path of its own
---

Issue #60's local slice (root Decision 700). The page listed what `mcp.status`
said about a running session and nothing else, and the only way in was YAML by
hand. It now opens on `mcp.list` with the session's id and `skills.list`
(`Troupe.Client.sources/1`), so every server the user's `mcp.json` and the
workspace's `.troupe/mcp.json` give this workspace is listed with its layer, its
file and — where the session runs it — its state, and every skill beside them.
`/mcp import <path>` and `link <path>` are `mcp.add`, `/skills import` and `link`
are `skills.add`, `remove` and `unlink` the two `remove` methods and `check` is
`mcp.check` on this session (`Troupe.Client.manage_sources/3`); `--workspace`
names the scope. On the page `c` checks the selected server, which is also how one
written after the session began is started, `d` writes `disabled` through
`mcp.add` and checks, and `x` removes, a removed server being checked afterwards so
the session stops it. All of it goes through the daemon: the TUI reads and writes
no `mcp.json` itself, so the desktop app sees the same set, and a remote session's
page says its servers are its profile's. The status line's `mcp:` count is fed from
the same listing. Proof: `test/troupe/mcp_page_test.exs`, an import and a link
typed into the TUI over the embedded daemon, the stub started with `c`, and the
remove key.
