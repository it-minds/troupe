---
number: 963
title: "A desktop screen entered before this computer's daemon linked to the person, or before its socket opened again, says the daemon is ready now and offers a refresh that remounts that screen; the app never remounts a screen uninvited"
date: 2026-10-28
status: accepted
paths:
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/test/daemon-ready.test.tsx
symbols:
  - DaemonReady
  - placeOf
gist: "A screen entered before the daemon linked or its socket reopened shows a banner with Refresh (a remount of that screen, keyed in App.tsx); gone at refresh or the next screen; no screen is remounted uninvited"
---

The daemon starts slowly beside the desktop app, and a person who opened a screen
meanwhile had to click to another screen and back to see what the daemon had for it.
The app finds the daemon, dials it, asks its identity and only then hands the screens a
client; signed in to a plane, it then hands the daemon the plane token, which links it to
the person. Every screen reads through the client, so a screen entered before the client
arrived asks when it does: its effects depend on the client, and the one list is polled.
But two later transitions reach no screen:

- **The hand-over.** A screen entered with the client there and the daemon not yet
  linked asked at once, and the daemon refused as not signed in (artifacts, memory, what
  a new session may start as). Nothing asks again when the link lands: a screen's effects
  depend on the client, which is the same object before and after.
- **A socket that opens again.** The client follows a daemon that restarted, and
  `useDaemon` counts the reopenings (`opened`); the first-run screens ask again at each
  (916), and an open session's view resubscribes from its cursor. Every other screen
  holds what the earlier daemon had.

So `App.tsx` keeps, per screen entered, how ready the daemon was: how many times its
socket had opened again, and whether it was linked. When the daemon is further along than
the screen on show saw (`opened` grew, or `linked` turned true), a banner above the screen
says "This computer's daemon is ready now; this screen opened before it was." with
*Refresh*. Refresh bumps the key on the screen's element, which remounts that one screen
and nothing else; the banner goes at the refresh and at the next screen (a move is a
change of `placeOf(where)`, so the rail's entry for the screen on show pressed again is
not one). The window is never reloaded.

**Why not remount by itself.** A remount loses whatever the person is in the middle of:
a draft in the composer, a selection in the gallery, a form on the start screen. The app
cannot tell a screen that would lose nothing from one that would, so it offers rather
than does. The screens that know to ask again (first run, setup, an open session's
subscription) keep doing so; the banner is said there too, which is harmless and true.

**Why not the client's arrival, or the daemon's first list.** Both reach every screen
already: the effects depend on the client, and the list is a snapshot every screen reads
live. A banner at either would offer a refresh that changes nothing. A token renewal
links the daemon again with the same identity, so `linked` does not turn and no banner
is said for it.

**Proof.** `clients/gui/apps/desktop/test/daemon-ready.test.tsx`: a screen entered
while `identity.link` is held back shows the daemon's refusal, then the banner once the
link lands, and Refresh shows the rows; the banner goes at the next screen, which says
nothing when entered after; a daemon stopped and started again on its port brings the
banner once the list's poll dials again.
