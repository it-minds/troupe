---
number: 789
title: Erasing a private session on the daemon erases it at the plane first, as an erasure started there goes, and erases nothing where the plane cannot be asked; a sealer whose report the plane refuses as stale stops
date: 2026-10-05
status: accepted
issue: 432
paths:
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
gist: Erasing a private session on the daemon erases it at the plane first, as an erasure started there goes, and erases nothing where the plane cannot…
---

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
- **A stale report stops the sealer.** `Sealer` now takes it as the fence it is: it seals
  nothing more, not even in `terminate/2`, and stops with `{:shutdown, :stale_version}`;
  `seal_now/2` answers `{:error, :stale_version}`. The daemon's sealers are `restart:
  :transient`, so a crash still restarts one and this does not; they were `:permanent`,
  and a stopped one would have been started again from its first options, at the old
  epoch. The session stays `elsewhere` (785) until it is claimed here, and
  `Private.stop/1` allows for a sealer that stopped between the lookup and its last seal.
