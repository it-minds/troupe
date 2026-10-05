---
number: 698
title: The slash commands a client offers are one table in the harness, `Troupe.Commands`, published as `commands.list`; a client keeps only the code that runs each one, and the TUI's suite holds its set equal to the table
date: 2026-09-26
status: accepted
issue: 124
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_core/test/troupe/commands_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/commands_list_test.exs
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
gist: The slash commands a client offers are one table in the harness, `Troupe.Commands`, published as `commands.list`
---

Issue #124.
The TUI had three lists that had to agree (the dispatch table, Tab completion and
the window-path commands), `/help` opened the settings, and the desktop app had no
commands at all, so nothing told a person what they could type. Now every built-in
has one entry — name, aliases, section, a one-line summary, usage, arguments, what
it needs (`availability`) and where it came from (`source`) — and the agents are
entries in a section of their own, described by their definition rather than
pretending to be built-ins: the same primaries `agents.list` answers with, so a
palette and a session picker never disagree. `availability` is a requirement the
client judges, not a verdict the harness passes (`always`, `window`, `local`,
`plane`), so a client shows a command it cannot run greyed with the reason rather
than hiding it, which is how somebody learns the tool. `/goal` and `/loop` (#59)
are entries like any other. A worker answers the same method through the same
handler, so a pod's palette lists its bundle's agents. Still owed to #124, and out
of this: commands defined as markdown files, and generating `troupe --help` and the
docs' command reference from the table. Proof: `Troupe.CommandsTest`,
`Troupe.Gateway.CommandsListTest` (over a socket) and the TUI's
`Troupe.CommandPaletteTest`, which fails the moment the two sets differ.
