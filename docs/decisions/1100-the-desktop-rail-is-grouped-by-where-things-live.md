---
number: 1100
title: "The desktop's rail is grouped by where things live: the work both kinds of install have, On the platform, On this computer; a side the install lacks has no group and no row, a side that is down keeps its group dimmed with its state by the heading, each side's state is said once in a row at the rail's foot, and setup is a card at the top until the daemon says it is finished"
date: 2026-11-24
status: accepted
issue: 1199
paths:
  - clients/gui/apps/desktop/src/views/Rail.tsx
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/hooks.ts
  - clients/gui/apps/desktop/src/views/Onboarding/Step.tsx
  - clients/gui/apps/desktop/src/styles.css
symbols:
  - RailBody
  - onAbsentSide
  - localSide
  - planeSide
  - setupProgress
gist: "Rail groups: (both) Sessions, Waiting, Review if a plane, Artifacts, Memory; On the platform; On this computer. Absent side: no group, no row, its screens fall back to Sessions. Down side: group dimmed, state by heading, items open. State in rows at the foot; setup a card until done"
---

Issue #1199, from the maintainer's mock. The rail listed every destination in one column
whatever the install was, and said each side's state only in small lines under the name.

- **The edition is read from the install.** A plane is a side unless Local only is on (an
  install with no plane configured is at the sign-in, not in the shell). This computer is a
  side where the shell finds a daemon or the window has been told of one (`canFind`, an
  endpoint, a status other than `unsupported`, or `capabilities().localSessions`); a daemon
  let go of with Disconnect stays a side that is down until the next load, so the page that
  says how to connect it again does not vanish under the person. A screen of a side the
  install lacks gives way to Sessions.
- **Down is dimmed, not hidden.** Hiding a group at every daemon restart would make the rail
  jump; its items still open because their pages say what is wrong. Review is in the first
  group and offered only where the install has a plane; Review and Profiles opened while the
  plane is offline say so instead of drawing nothing.
- **The words.** This computer: Connected, Starting… (looking for the daemon), Not running
  (absent, not answering, or let go of). Platform: Connected; Reconnecting… while signed in
  and the list's last ask of the plane failed (the next poll asks again); Offline when not
  answering, answering with a sign-in that ended, or not serving this version, which the
  row's title says. Offline's periodic ask is not shown as Reconnecting…, which would flash
  amber every fifteen seconds. The signed-in block keeps name, teams, shell and Sign out.
- **The rows open a page.** This computer's opens This computer; the platform's opens the
  sign-in while offline, which asks the plane again, and otherwise This computer, which names
  the plane the daemon is linked to and holds Local only (Profiles where there is no local
  side). A view of a connection's details is a later issue.
- **Setup** is asked of the daemon in either mode (it was only in local mode) and again as
  the person leaves Setup; unfinished, the card counts the daemon's own steps by the run's
  own names; finished, Setup sits by Appearance with a check. With no daemon, Setup shows how
  to connect one rather than send the person to This computer.
- **Colours** are the theme's: accent and `--waiting-*` for the reserved colour,
  `--running-*` for connected, `--queued-fg` for on its way, `--bg-hover` for hover and the
  current item, `--border-hairline`, `--bg-canvas` under the rows. The connected dot's glow
  is the one glow besides the footlight; the card is a flat tint, not the mock's gradient.

Not chosen: keeping one list and greying the absent side's items (the issue's complaint);
hiding a down side (the jump). Undone, a remote-only install shows a daemon's pages as if
one were expected, and the state of each side goes back to being said in two places.
