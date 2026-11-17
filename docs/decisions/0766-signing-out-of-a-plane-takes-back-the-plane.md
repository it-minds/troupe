---
number: 766
title: Signing out of a plane takes back the plane token the client handed the daemon, and the daemon seals nothing until somebody signs in again; the link stays
date: 2026-10-04
status: accepted
issue: 381
paths:
  - ARCHITECTURE.md
gist: Signing out of a plane takes back the plane token the client handed the daemon, and the daemon seals nothing until somebody signs in again
---

- **A command of its own, not `identity.unlink`.** `identity.sign_out` names the plane
  and the person (`plane_url`, `subject`). The daemon forgets its token if it is for
  that plane and that person, stops every sealer (`Private.suspend/1`), and answers
  `signed_out`; the label stays. Unlinking was the other way, and was not taken: in the
  desktop app linking is the person's own choice on *This computer*, which a sign-out
  would undo, so signing in again would carry nothing on until they chose it again;
  and a daemon left unlinked is one the next `troupe login` links, as whoever that is,
  and a link with a token carries on every private session the daemon has (764),
  whoever made it. Taking back the token leaves the daemon as a restart does, which
  764 already carries on from.
- **The daemon decides whose token it is.** It compares the plane, up to a trailing
  slash, and the subject it was linked under, so a client signing somebody else out,
  or out of another plane, takes nothing, and needs no `identity.get` first. Without
  `subject` it is the token for that plane, whoever it is for: a TUI signed in before
  this has no subject on disk, and taking back a token that was somebody else's costs
  them a hand-over at their next renewal, where keeping the person's own would go on
  sealing for up to a token's lifetime after they signed out.
- **Sealing stops and nothing is lost.** The token goes first, then the sealers, so the
  last seal each makes on its way down finds no token and calls nobody; its events are
  in the log on this disk, and the session's key goes with the sealer. A private
  session made while signed out is local for now (`syncing: false`), as on a daemon
  nobody has linked. The next link with a token runs `resume` as after a restart: each
  carries on from the row's `last_seq` at its epoch, and one the plane has never heard
  of from its first event.
- **The TUI.** `troupe logout [PLANE_URL]` and `--all` read who was signed in where
  before forgetting it, then, where a daemon is running (`spawn: false`: none is
  started to be told), send `identity.sign_out` for each plane, and say so where the
  daemon let go of a token. Nothing is said about a daemon that is not running or
  that held no token of the person's. The subject is `credentials.json`'s `sub`, the
  plane's subject at the last exchange, a label now written beside the refresh token
  at login and at every refresh. A TUI still running hands nothing more over: its
  renewal reads that file first.
- **The desktop app.** *Sign out* sends it with the sign-in's plane and subject before
  forgetting the sign-in, without waiting for the answer (`signOutIdentity`).
- **Signed in elsewhere still.** The other client, signed in as the same person at the
  same plane, hands a token over again at its next renewal or reconnect, and sealing
  carries on: the person is still signed in there.
