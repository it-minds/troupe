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

Issue #381,
the first item of D61, following 764. `troupe logout` forgot `credentials.json` and
nothing else, and the desktop app's *Sign out* forgot its own sign-in: a daemon either
of them had handed a token went on registering and sealing private sessions with it
until it ran out.
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
- **Proof:** the TUI's `private_link_test` against `FakeRemote` (after `troupe logout`
  the daemon holds no token and says so, keeps the label, and registers a private
  session made then nowhere, and signing in again hands one over; `--all` likewise; a
  daemon linked to somebody else keeps theirs; with no daemon running nothing is said
  and none is started), two of the four failing on the tip. The gateway's
  `private_test` against MinIO and OpenBao (`Plane.sign_out` forgets that plane's and
  that person's token and nothing else, and keeps the label; a session sealing when
  the person signs out stops, nothing more reaches the plane, its last seal included,
  and the next link carries it on from `last_seq`, the turn's event and one written
  while signed out in a second segment; through the daemon, `identity.sign_out` for
  somebody else or another plane takes nothing, and for the person takes the token and
  the sealer and keeps the label). The desktop app's `private-link` test (*Sign out*
  tells the daemon the plane and the subject, and the token goes and the link stays;
  a daemon linked to somebody else keeps theirs), failing on the tip. And the
  installed daemon and `troupe`, with scratch homes, against the plane stand-in of
  764's proof: `troupe login` and `troupe run --headless --private` registered a
  session and sealed it through its eleventh event; `troupe logout` said the daemon no
  longer held a token; a turn given to that session afterwards and a private session
  `troupe run` made then reached the plane with nothing, still nothing a minute and a
  half later with the old token still good; after `troupe login` the next `troupe run`
  handed a token over, and the daemon sealed the first session on from its twelfth
  event at epoch 1 and the one made while signed out from its first; `--all` said the
  same, and with no daemon running `troupe logout` said nothing about one and started
  none.
