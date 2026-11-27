---
number: 1113
title: "The desktop's palette lists a built-in that opens a page of This computer's (settings, models, servers, skills, unlink) only where the install has a daemon, by the rail's own rule for which sides it has"
date: 2026-11-26
status: accepted
issue: 1202
paths:
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/App.tsx
symbols:
  - onAbsent
  - SCREEN_OF
gist: "Palette: a built-in that opens a screen of a side the install lacks is left out, not greyed; the sides are the rail's (onAbsentSide, App's sides). Setup stays; a command that could run in some session stays greyed"
---

Issue #1202. Since the rail was grouped by side (1100), a screen of a side the install lacks
gives way to Sessions. The palette still offered `/settings`, `/models`, `/mcp`, `/skills`
and `/unlink` in a browser told of no daemon, and choosing one landed on the session list
with no sentence saying why.

- **Left out where the install lacks the side.** A built-in that opens a page of This
  computer's (`local`, `connect`) is not listed without a daemon. The test is the rail's
  `onAbsentSide`, over the `sides` the app already computes, handed to the session and on
  to the palette: there is no second notion of which sides an install has, and a command
  that opened a plane's page would be left out of a local-only install the same way. None
  does: `/publish` opens a dialog that says the daemon's refusal under Local only, so it
  stays and speaks.
- **Where the person connects a daemon** is the Setup page's Connect section, which the
  palette's Setup item and the rail's Setup keep. Nothing is said in the palette about the
  missing side: a list that does not offer a thing needs no sentence about it.
- **Greyed stays for the rest.** 984's rule, a row greyed with its reason, holds for a
  command this client could run in some session (a branch's, a session on this computer's,
  a plane command before the daemon is known to be signed in). This decision narrows it only
  for what cannot work on this install at all, which 984 already leaves out for the terminal
  client's own rows.

Not chosen: keeping the rows and saying, on choosing one, that there is no daemon (the
issue's second branch: a row that can only refuse); a private list of which commands
are This computer's in the palette beside the rail's. Undone, a remote-only install lists
commands that land on Sessions silently, and the palette and the rail disagree on what
the install has.
