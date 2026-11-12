---
number: 976
title: "The desktop app's Memory and Artifacts read and change the person's own straight from the plane it is signed in to, by its sign-in's gated rpc as the console does; this computer's daemon is asked only what this computer holds, and carries the person's own only where the app is not signed in; and a screen with neither says why in the daemon's actual state"
date: 2026-11-12
status: accepted
supersedes: [954]
paths:
  - clients/gui/packages/client/src/own.ts
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/views/OwnMemory.tsx
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/desktop/src/views/bits.tsx
  - clients/gui/apps/desktop/test/own-things-from-the-plane.test.tsx
  - docs/user/memory.md
  - docs/user/artifacts.md
symbols:
  - PlaneOwn
  - OwnPlane
  - unreachedWords
gist: "Signed in, Memory/Artifacts use PlaneOwn (auth.rpc, gated); daemon only for its copy's status, config.changed, publish; daemon route only unsigned; no-route sentence from daemon.status"
---

# Memory and Artifacts read from the plane when the app is signed in

## Context

The maintainer, 2026-11-12: the Memory and Artifacts tabs said the daemon was not
running while it was, and they should not need it when the app is connected to the
plane; memory from there should be real and read.

Decision 954 had the app read both through this computer's daemon, which forwards the
plane's `me.memory*`, `memory.in_effect`, `admin.memory.*` and `artifact.*` as the person
it is signed in as. Two things followed from that:

- Each screen keyed its whole state on `daemon.client` being there and said "This
  computer's daemon is not connected" whenever it was not. `useDaemon` has no client in
  more states than "no daemon": while the shell is still finding or starting it (up to
  thirty seconds), between two dials when its endpoint changes, and after a first dial
  that failed, which is never tried again. A browser build has none at all. The sentence
  said nothing of which.
- With the daemon connected, every answer was the daemon's sign-in's, not the app's. A
  daemon signed in to no plane, or to another, or from before a forwarded method, made
  the screens say the daemon's refusal ("this computer's daemon is not signed in to a
  Troupe plane") while the app itself was signed in and could ask the plane directly.

## Decision

- **Signed in, the plane.** Where the app has a plane sign-in and Local only is off, the
  screens are handed a `PlaneOwn` (`packages/client/src/own.ts`) built on that sign-in's
  own `rpc`. It asks the plane's methods of the same names and answers in the shape the
  daemon hands a client: `plane_url` added, and `me.memory` asked with `entries` and put
  back from the plane's signed shape (the person's own as `user`, the levels as
  `documents`) into the person's own with the levels beside it, each team of theirs with
  no document listed empty, roles nobody's where the plane says none, as
  `Troupe.Gateway.Memory.own/1` does. Both implement `OwnPlane`, so a screen does not ask
  which it has.
- **The gate is unchanged.** Decision 926's one gate is the `fetch` every desktop sign-in
  is built with; `auth.rpc` goes through it, so Local only still refuses a call already on
  its way. Nothing here sends a plane request any other way.
- **The daemon keeps what is this computer's.** With a daemon connected, the Memory view
  still asks it `me.memory.status` (where this computer's copy stands, and what each
  session here read) at every read, and hears its `config.changed` for memory. The daemon
  answers `me.memory.status` by asking the plane and keeping the answer, so a save made
  straight to the plane reaches the sessions running here for their next turn, as a save
  through the daemon did, rather than at the next five-minute poll. Publishing a new version
  sends files from this computer, so the gallery's "Publish a new version" stays the
  daemon's and is offered only with one.
- **The daemon carries the person's own only where the app is not signed in** (offline,
  a plane that refuses this version): then the screens go through it and its own sign-in,
  as 954 had them. Under Local only neither is used, and the screens say so as before.
- **A screen with neither says why, truly.** The sentence follows `useDaemon().status`
  (`unreachedWords`): not running, did not answer (with its error), or a browser that
  cannot find it; while it is still being looked for, or between two dials, the screen
  waits rather than calling it absent.

This narrows Decision 954's "read through this computer's daemon" to the app when it is
not signed in, and Decision 955's "visibility moves in the app via the daemon" the same
way; the daemon's forwarded methods stay, for the terminal client and for that case. The
rest of 954 (Local only, the child window, entries) holds.

## Not chosen

- **Keep the daemon and fix only the sentence.** The screens would still show the
  daemon's sign-in's refusals while the app is signed in, which is the second half of
  the report.
- **Always the plane, the daemon never.** A person working offline, with the daemon
  signed in, would lose their memory and artifacts in the app for no reason.
- **Verify `me.memory`'s signature in the app.** The daemon verifies it because it keeps
  the copy its sessions read; the app only shows the answer it was given over its own
  signed-in TLS connection, as the console does.

## Proof

`clients/gui/apps/desktop/test/own-things-from-the-plane.test.tsx`: signed in to a fake
plane with no daemon, and with a connected daemon signed in to no plane, Memory shows the
plane's entries in effect and Artifacts its artifact, and neither says anything about a
daemon; the connected daemon is asked `me.memory.status` and nothing of the person's own.
Under Local only the plane is asked nothing. Offline with a daemon, memory goes through
the daemon; offline with a shell that found none, both say the daemon is not running.
On the tip (`d37507cf`) the first two failed with "This computer's daemon is not
connected" and "this computer's daemon is not signed in to a Troupe plane", and the
last with the same false sentence. The Memory and gallery tests from 954 and 957 run
against a fake plane whose memory and artifacts the fake daemon keeps
(`packages/client/test/support/kept.ts`), unchanged otherwise.
