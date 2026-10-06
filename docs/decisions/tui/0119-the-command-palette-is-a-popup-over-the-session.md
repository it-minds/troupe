---
number: 119
title: "The command palette is a popup over the session, opened by `/` on an empty line, Ctrl-K with nothing typed, or `/help`, and it is a view over the harness's `commands.list`: the TUI keeps no list of its own beyond the clauses that run each built-in"
date: 2026-09-26
status: accepted
issue: 124
paths:
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/command_palette_test.exs
gist: The command palette is a popup over the session, opened by `/` on an empty line, Ctrl-K with nothing typed, or `/help`, and it is a view over the…
---

Issue #124, root Decision 698. The three lists in `server.ex` collapse
into `@builtins`, which a test holds equal to the harness's table; aliases, Tab
completion and which commands take a window path all come from the table
(`canonical/2`, `command_names/1`, `takes_window?/2`), so adding a command is one
entry there and one clause here. What is typed while the palette is open filters by
name, alias and summary; ↑↓ and PgUp/PgDn move over the rows, which keep their
sections; Enter runs the row, or puts it on the line when it wants an argument or
a window the person has to name; Tab and Space put it on the line too, so
`/merge 2⏎` types exactly as it did before there was a palette; Esc closes it with
the line clear. A row the client cannot run now is greyed with the reason — no
window activated, a session on a plane — and the detail box says why. `/settings`
keeps its own entry and `/help` (and `?`) now means help. The session stays on
screen behind the popup, and a command picked from a window acts on that window.
The box's slash is a prompt: a line that carries its own (one the palette put
there) is not shown with two. Proof: `test/troupe/command_palette_test.exs`.
