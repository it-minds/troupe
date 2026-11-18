---
number: 785
title: A daemon's `session.list` says a private session is private and how its sealing stands here, and `session.claim` takes one another device sealed last over on this one, where this copy holds what the plane has
date: 2026-10-05
status: accepted
paths:
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
gist: A daemon's `session.list` says a private session is private and how its sealing stands here, and `session.claim` takes one another device sealed…
---

- **What a row says.** `kind` (`local`, `private`, a pod's `team`), and for a private
  session `sync` and `device` (`Private.sync/1`): `current`, a sealer with nothing
  pending; `behind`, one with events pending, or one that does not answer a status
  within 250 ms because it is uploading; `paused`, no sealer: no token since the
  daemon started or the person signed out, no plane, or the session archived;
  `elsewhere`, the row named another device at the last link's `resume`, or a seal
  was refused `stale_version`, with `device` naming it where the plane did;
  `erasure_pending`, the row said so at the last link. Five where the slot named
  four, because not sealing and sealing behind ask different things of the person:
  the one waits for a sign-in, the other for a moment. What the plane said is kept in
  an ETS table the sealers' supervisor owns, and forgotten when a sealer starts or the
  session is erased here. A listing never asks the plane: the desktop app lists every
  four seconds, and a laptop is offline most of the time it is on.
- **`session.claim {session_id}`, `admin`.** Where a session lives is the person's
  say, as archiving and erasing it are. `Private.take_over/2` reads the row
  (`session.get`); one that names this device is carried on, a sealer started if none
  runs, and not claimed again, so a second claim moves nothing; another device's is
  claimed with the row's `epoch` through `claim/3`, a sealer still here that lost is
  stopped, and the session is sealed from the row's `last_seq` at the new epoch, as
  `resume` seals this device's. The answer is the row's `device` and `epoch` and the
  `sync`. Refusals: `not_found` with `erased` or `not_registered`, `stale_version`
  where another device claimed first, `unavailable` with `unlinked`, `invalid_params`
  for a session that is not private. A pod has no private session; a token for one
  session is refused it as not about that session.
- **Only the same history.** The event at the row's `last_seq` must be in this log
  with the row's `head_hash`, the `Event.hash` a seal reports of its last event; if
  not, `conflict` with `reason: "diverged"`, and nothing changes. The slot did not
  say this. Without it a claim on a machine whose copy the other device sealed past
  would seal this copy's later events after the other's, two histories under one
  prefix that no restore reads back. Restoring the plane's copy over this one first
  is what would let such a claim through; it is not done here.
