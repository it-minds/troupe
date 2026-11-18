---
number: 985
title: A desktop screen entered before this computer's daemon was ready is drawn again by itself when the person has typed nothing on it; the banner with Refresh stays for a screen with a draft and for a session
date: 2026-11-15
status: accepted
issue: 898
supersedes: [963]
paths:
  - clients/gui/apps/desktop/src/App.tsx
symbols:
  - DaemonReady
  - hasDraft
gist: "Daemon ready after a screen opened: remount it by itself if nothing is typed there; banner + Refresh only with a draft, and on a session (its remount loses the place)"
---

Issue #898. Straight after sign-in the session list (or the launcher) is entered before
the daemon is linked to the person, so the first screen a person met said "This
computer's daemon is ready now; this screen opened before it was. Refresh" on a list they
had not touched. Decision 963 offered rather than did, because a remount loses what the
person is in the middle of and the app could not tell a screen that would lose nothing
from one that would. It can tell the main case: whether the person has typed on it. This
amends 963 there (its `supersedes` is that part); the rest of it, what counts as the
daemon becoming ready and the remount being of the one screen, stands, as does Decision
975's new-session screen without a banner.

- **Typed is heard, not guessed.** `App.tsx` listens on the screens' container (`<main>`)
  for `input` and `change` events, in the capture phase, and keeps the fields they came
  from for the screen on show; a move to another screen or a refresh starts an empty set.
  `hasDraft` asks whether any still on the screen holds something: a text field or a text
  area with text in it, or any other control the person changed (a select, a box). A
  controlled field's `defaultValue` does not reliably say what the person changed, since
  React may keep its `value` attribute in step; the event says it.
- **Nothing typed: drawn again.** When the daemon becomes ready for the screen on show
  and it has no draft, the app remounts that screen at once, and no banner is drawn even
  for a frame. The screen asks the daemon what it asks at its start again, which is what
  Refresh did.
- **A draft: the banner.** With a draft, the banner and Refresh are as 963 has them, and
  they stay until Refresh or the next screen. A draft cleared afterwards does not then
  remount the screen under the person's hands.
- **A session: the banner.** A session's remount reads its transcript again from the
  top, which loses the person's place in it and jumps, and its subscription already
  follows a daemon that restarted. So a session's screen keeps 963's banner, draft or not.
- **Not chosen.** Remounting every screen whatever was typed (loses drafts, which is
  963's reason). Keeping each screen's own fields across a remount (every screen would
  have to lift its state, for a moment that happens once per launch).

**Proof.** `clients/gui/apps/desktop/test/daemon-ready.test.tsx`: Tools and skills,
entered while `identity.link` is held back, asks the daemon again by itself once the link
lands and never shows the banner (it failed before the change: the banner was shown and
nothing asked again until Refresh); the list with a search typed shows the banner, keeps
the search, and Refresh takes it away; the banner goes at the next screen; a daemon
stopped and started again on its port has Tools and skills asked again with no banner; a
session shows the banner.
