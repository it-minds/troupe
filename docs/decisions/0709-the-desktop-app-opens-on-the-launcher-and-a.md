---
number: 709
title: The desktop app opens on the launcher, and a person who would rather start on the list says so once
date: 2026-09-27
status: accepted
issue: 52
paths:
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/views/Launcher.tsx
  - clients/gui/apps/desktop/test/launcher.test.tsx
  - clients/gui/apps/desktop/test/signin.test.tsx
  - clients/gui/docs/design/DESIGN.md
gist: The desktop app opens on the launcher, and a person who would rather start on the list says so once
---

Issue #52, amending 704, which built the launcher and kept the
list as the first screen; the comp opens on the launcher, and so does the app now.
- **The choice is at the foot of the screen it is about.** "Skip this screen when
  Troupe starts" is a checkbox in the launcher's footer, where the comp keeps its
  shortcuts, and from the next start the app opens on the list. It moves nothing
  now: the preference is read once, when the app starts. The lockup in the rail
  still opens the launcher from anywhere, with the box ticked.
- **Turned back beside the appearance.** A person who skipped the launcher no longer
  meets its checkbox, so the same preference is on the Appearance screen under the
  notifications, as two cards — Home, the lockup's own name for the launcher, or
  Sessions. It is kept where the theme and the notifications are, as `start` in the
  app's preferences on this computer.
- **A first run is not a start.** On a fresh machine the first run's questions (705)
  end where they did, on the session they started or on the list, and the launcher
  comes on the starts after. Sign-in, and the theme a first sign-in asks for, still
  come before it.
- **The app's tests say which screen they start on.** The suites that open a session
  from the list start where a person who chose the list starts (`startOnTheList` in
  the desktop app's `test/support.ts`); `launcher.test.tsx` is the one about the
  first screen, and the local-only test passes through the launcher on its way to
  every other screen.
- **Proof:** `launcher.test.tsx` (the launcher first; the box ticked and a restart on
  the list, the lockup still reaching the launcher, the box unticked and the launcher
  back; Appearance both ways; a first run ending on the list and the launcher at the
  next start), the first-run test's relaunch now on the launcher, the GUI's
  typecheck and test suites, the desktop build, `tokens:check`, `icons:check`, and
  the app against a fake daemon in a headless browser, light and dark, at 1280px and
  380px, on the pull request.
