---
number: 789
title: Erasing a private session on the daemon erases it at the plane first, as an erasure started there goes, and erases nothing where the plane cannot be asked; a sealer whose report the plane refuses as stale stops
date: 2026-10-05
status: accepted
issue: 432
paths:
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_gateway/test/support/fake_plane.ex
gist: Erasing a private session on the daemon erases it at the plane first, as an erasure started there goes, and erases nothing where the plane cannot…
---

Issues #432 and #433, following 756, 784 and
785. The daemon's `session.erase` of a private session erased the copy on this disk and
nothing else: the session's sealer went on, the plane's row stayed active and the
sealed copy stayed under a live key, so another of the person's devices still listed
it and could claim and restore it. And `Sealer` ignored what its report was answered:
refused as `stale_version`, it went on sealing at its old epoch beside the device that
held the session now, which 785 left listed `elsewhere` meanwhile.
- **The plane first.** `Private.erase/2` asks the plane's `session.erase`, which
  destroys the key itself (756). Once it has, the daemon does for this one session
  what `apply_erasures/1` does for an erasure started elsewhere: the sealer stops, the
  copy here goes, and `session.erased` tells the plane, which deletes every version
  under the prefix; one the plane could not be told about it names at the next link.
  The answer is `erased: true, state: "erased"`. The plane is asked before the sealer
  stops, so a refusal changes nothing; the sealer's last seal on its way down is then
  refused by the plane, and whatever got through before is under the prefix it
  deletes.
- **`erasure_pending` until the key is gone.** Where the key manager refused, the
  answer is `erased: false, state: "erasure_pending"`; the sealer and the session stop,
  the copy here stays and is listed `sync: "erasure_pending"`, and it goes with the
  key: at the next link, whose `session.erasures` the plane answers after trying the
  key again, or at the next `session.erase`. Kept rather than dropped at once, because
  the listing is where a person sees that an erasure did not finish, and because 756
  has a device's copy go after the key, as the objects do.
- **Nothing erased where the plane cannot be asked.** The slot allowed either erasing
  the copy here and saying what remained, or refusing; this refuses, as the issue put
  it: `unavailable` with `reason: "unlinked"` (no token), `"not_owner"` (below), or
  why the plane did not answer, and `plane_url`, the plane the daemon was last linked
  to, where the session is sealed and can be erased. Erasing only this copy would
  leave the key and the sealed copy, restorable on another device, and drop the index
  entry `resume/1` and `apply_erasures/1` work from, so nothing on this machine would
  ever finish it. Refusing loses nothing: the copy is on the person's disk, and every
  signed-in client links the daemon on its own (764). What it costs: a private session
  on a daemon nobody links again cannot be erased through Troupe. One the plane has no
  row for (`not_found` without `reason: "erased"`) was never sealed, and is erased
  here.
- **Only with the owner's token.** A session whose `owner` (784) is not the person
  linked is refused `not_owner` before anything is asked, as `resume/1` leaves it
  alone: the plane is asked nothing about it with somebody else's token.
- **One shape.** A local session's answer gains `state: "erased"` too.
- **A stale report stops the sealer.** The daemon's report already answered
  `{:error, :stale_version}`. `Sealer` now takes it as the fence it is: it seals
  nothing more, not even in `terminate/2`, and stops with `{:shutdown,
  :stale_version}`; `seal_now/2` answers `{:error, :stale_version}`. The daemon's
  sealers are `restart: :transient`, so a crash still restarts one and this does not;
  they were `:permanent`, and a stopped one would have been started again from its
  first options, at the old epoch. The session stays `elsewhere` (785) until it is
  claimed here, and `Private.stop/1` allows for a sealer that stopped between the
  lookup and its last seal. A pod's reports are cast and answer nothing, so a worker's
  sealer is as it was. This revises 785's "Not in this", which left it running.
- **Not in this:** no client erases a daemon session yet (`DaemonClient.eraseSession`
  exists and nothing calls it), so neither the desktop app nor the TUI says
  `erasure_pending` or a refusal's `plane_url` from this answer. And a seal writes the
  manifest before it reports, so a sealer that has lost the session overwrites the
  manifest once, at its old epoch, before it learns so; the next seal of the device
  that holds it writes it back.
- **Proof:** the gateway's `private_test`, against MinIO and OpenBao with the plane
  stand-in, which now answers `session.erase` as the plane does (the key first,
  `erasure_pending` while the key manager refuses, tried again at `session.erasures`).
  A sealer whose session another device took is refused at its next report, answers
  `{:error, :stale_version}`, stops with `{:shutdown, :stale_version}` and is not
  started again, and a turn's event and the interval after it upload and report
  nothing more at its epoch; the session is `elsewhere`. Through the daemon: erasing
  a private session sealed here stops its sealer, the row is `erased`, the device
  acknowledges once, every version under the prefix goes and the session is not
  listed; with the key manager refusing it answers `erasure_pending`, the sealer stops,
  the session is listed `erasure_pending` with its objects in place, erasing again
  answers the same, and the next link once the key manager is back erases the copy
  and the objects; after a sign-out it is refused `unlinked` with the plane's URL and
  the plane asked nothing; and linked by somebody else it is refused `not_owner` and
  the plane asked nothing about it. The first four failed on the tip of #431's
  branch: a second segment at epoch 1 after the refusal, and `erased: true` with the
  sealer running and the row untouched, or, signed out, the copy erased. And the
  installed daemon, with scratch homes and the fake provider, through the client
  library, against a stand-in on loopback signing real assertions through the
  development OpenBao and real MinIO URLs: two private sessions sealed through their
  eleventh event; `session.erase` of one answered `erased: true, state: "erased"`, the
  stand-in saw `session.erase`, the key present before and gone after, then
  `session.erased`, and deleted both versions under the prefix; the other, claimed by
  "another laptop" at epoch 2, had its next seal (events 12 to 20) refused, the daemon
  logged that it had stopped sealing, a third turn uploaded nothing, and it was listed
  `elsewhere`; signed out, erasing it was refused `unlinked` with the stand-in's URL
  and nothing reached the stand-in.
