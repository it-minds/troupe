---
number: 984
title: "A command's row says what it does in words true in every client, with a client's own words beside them where it runs the command differently (`summaries`, `details`); `availability` `tui` marks the terminal client's own commands, which the desktop app leaves out; and an agent's row in the desktop palette switches the session by the head's rule"
date: 2026-11-15
status: accepted
issue: 898
supersedes: [698]
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/mix/tasks/troupe.cli.reference.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/gui/packages/client/src/types.ts
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/src/views/AgentSwitch.tsx
symbols:
  - Troupe.Commands.for_client/2
gist: "summary/detail are client-neutral, summaries/details hold a client's own; tui rows are hidden by other clients; desktop agent rows switch the session like the head"
---

Issue #898. The desktop palette read the table the terminal client's palette reads, word
for word: `/quit` "Leave the terminal client; the session carries on" (its desktop runner,
`window.close()`, does nothing in the browser build), `/cancel` "Stop a branch mid-turn
and remove its window" in an app with no windows, `/sessions` "This directory's sessions"
on a platform session, `/upload` greyed as "not in the desktop app yet", and `/build` and
`/plan` greyed as "only for a session on this computer" while the head's agent switch
beside the palette switched to them. Decision 698 made the table one; this amends it in
three places (its `supersedes` is that part).

- **Neutral words, and a client's own beside them.** `summary` and `detail` stay on
  every row and say what the command does in words true in any client. A row whose
  client runs it differently enough that the one sentence names what that client has not
  got carries `summaries` and/or `details`: maps from a client's name (`tui`,
  `desktop`) to its own sentence, present only on such rows, so the wire does not grow
  for the rest. A client shows its own where there is one and the neutral one otherwise.
  `Troupe.Commands.for_client/2` makes the choice for a client, and the terminal client
  applies it in `Troupe.Client.command_table/1` (the palette, Tab completion, the
  settings' help), in `troupe --help` and in `mix troupe.cli.reference`; the desktop
  palette makes it as the table arrives. A row from a harness before the maps has
  neither, and reads as it did.
- **`availability` gains `tui`.** The terminal client's alone: `/quit` (leaving that
  client) and `/upload` (reading a file from where the terminal started). The table
  already carries what a command needs as `availability`, which every client judges, so
  this is one more value of it rather than a second field (a `clients` list) that a
  client would have to read beside it to know whether a row runs. The terminal client
  treats it as `always`; any other client leaves the row out of its palette, which
  DESIGN.md §8 asks of a thing that cannot work there: 698's "greyed with the reason,
  never hidden" stays for everything a client could run in some session (a branch's
  `/merge`, a plane's `/publish`), not for a command that has no meaning in it. An older
  desktop build shows a `tui` row as it showed an unknown one. The desktop app also
  drops a `window` argument from a row's usage, and its example, since it has no windows.
- **An agent's row switches, by the head's rule.** In the desktop palette an agent's row
  runs `profile.switch` to it, as the head's agent switch does (Decision 841), and sends
  what was typed after the name as the next message, after the switch, so its usage reads
  `/plan [message]` there. It is enabled
  where the head's switch would switch to it: the session's own listing
  (`agents.list` for the session, `sessionAgents` in `AgentSwitch.tsx`, the list the
  switch reads) offers it as a primary it can run, and the person may change the session
  (not read only); never greyed while that listing has not answered. A function agent
  such as `/ask` is in the table on a laptop and not a primary, so it still says to start
  a branch from the terminal. The row's `availability` `local` is the terminal's branch,
  which the desktop does not start, so it no longer greys the row on a platform session.
  The terminal client's agent rows are unchanged: they start a branch.
- **Not chosen.** Hiding every command the desktop has no runner for (`/merge`,
  `/observer`): those are the tool's and a person learns them from the list, and a later
  desktop may run them. A `usages` map: the only client-specific part of a usage is the
  window argument, which the desktop drops by its kind.
