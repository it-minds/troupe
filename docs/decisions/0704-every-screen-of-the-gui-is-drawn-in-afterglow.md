---
number: 704
title: Every screen of the GUI is drawn in Afterglow, the launcher and the full-screen "new session" with them; a session doing nothing is `idle`, its own status with no colour, so `queued` can be the comp's amber
date: 2026-09-27
status: accepted
issue: 52
paths:
  - clients/gui/docs/design/DESIGN.md
  - clients/gui/docs/design/themes/THEMES.md
gist: Every screen of the GUI is drawn in Afterglow, the launcher and the full-screen "new session" with them
---

Issue #52, part 2 of 2, on the tokens
702 laid down. The session view (transcript, tool calls, the agent's and the
harness's questions, approvals), the inbox, review, This computer with its models
and servers panels, appearance and the command palette are restyled to the comp;
the two screens the comp has that neither part listed are built. Nothing behaves
differently: the same protocol calls, the same words on the buttons.
- **The launcher is behind the lockup, not the first screen.** The comp opens on
  it; the app still opens on the one list, because the list is the whole idea
  (Sessions.tsx says so) and the app's tests and habits are built on it. The lockup
  in the rail opens the launcher — three tiles (new, open, what needs you), the
  three most recent rows, what this machine is — and every tile leads back in.
  Opening on it instead is one line in `App.tsx`, if the product wants it. (709
  reverses this: the app opens on the launcher, and a person may choose the list.)
- **Casting a troupe is a screen, not a dialog.** `StartSession` moved out of the
  list into the shell (`where.screen === "new"`), as the comp draws it: where it
  runs as two tiles, then the questions that follow from the answer. The list's
  button and the launcher's tile both come here; the fields and the calls are the
  ones the dialog made.
- **Idle is not a colour.** `statusOf` mapped an idle session to `queued`, which
  forced 702 to make the queued pill grey. Idle is now a status of its own — an
  open, empty eye, the chrome's label grey on a strong rule, the comp's STOPPED —
  with no token, because doing nothing is the absence of a state; and `queued`
  takes the comp's amber for a message held while the troupe works. A session
  whose only open question is the workspace's trust question, asked at its start,
  reads as waiting like any other, and a test says so.
- **The structure grew, once more, and every theme carries the copy.** Three type
  roles the comp needed and 702 left without a token — `tile` (26px/900), `name`
  (14px/800, the byline) and `note` (14px/400) — a `border.edge` of 2px for a
  message's left edge, and `size.markDisplay` for the launcher's mask, in all four
  files, so `pnpm tokens` still finds them identical. No colour token was added.
- **Two comp values were not taken.** The in-progress task is lit in the
  machine's cyan, not the comp's pink: pink marks a person's decision and nothing
  else, which 702 held to and this holds to. The `ag-scan` keyframe is defined in
  the comp and used by nothing in it.
- **Room left.** The session head's subject column stacks the breadcrumb and the
  title and is where the next wave's goal line, loop controls and "while you were
  away" marker go.
- **Proof:** `pnpm tokens:check`, `icons:check`, the GUI's typecheck, its test
  suites (the app's grew from 13 to 18: `statusOf`, the trust question, the
  launcher), the desktop build, and every screen against `pnpm fake` and the
  client's fake daemon in a browser, light and dark, at 1280px and 380px, on the
  pull request.
