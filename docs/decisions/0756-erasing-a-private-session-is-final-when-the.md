---
number: 756
title: Erasing a private session is final when the plane has destroyed its key, which it does itself and at once; the session is `erasure_pending` until then, and its objects and the device's copy go when the owner's daemon next connects
date: 2026-10-03
status: accepted
issue: 348
paths:
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_protocol/lib/troupe/object_store/signed.ex
gist: Erasing a private session is final when the plane has destroyed its key, which it does itself and at once
---

- **The key, by the plane, now.** With the plane's own credential, whose policy has
  `delete` on `metadata/troupe/people/+/sessions/*` for exactly this and no rule for the
  data path (`Policy.plane/1`): every version goes and none could have been read. That
  revises 90's first sentence for a session with no pod and keeps its reason, since the
  component that decides to erase still cannot read what it erases. Under the owner's
  name at the key manager (755), looked up from their subject. No slot, budget slice or pod to give back, so the drain's park is
  not run, and that is what failed on the tip.
- **`erasure_pending` until it is gone.** A session state, for a private session whose key
  the key manager refused or could not be reached to destroy. Listed as it is, to its
  owner and to an administrator, so somebody can see an erasure did not finish. Nothing
  seals, keys, signs or lists for it: `session.register` (with `claim` or without),
  `session.assertion`, `session.presign` and `session.objects` answer `not_found` with
  `reason: "erased"`, as they now do for an erased one, and it is not forked.
  `session.erase` answers `erased: false, state: "erasure_pending"`, and
  `admin.session.erase` the same `state`. Erasing again tries again, and so does the
  owner's daemon connecting.
- **The objects when the daemon next connects.** It asks `session.erasures {device}`, the
  owner's erased private sessions this device has not acknowledged, as `pending_for/2`
  tells a pod on enrol; for each it stops the sealer, erases its own copy and answers
  `session.erased {session_id, device}`, and on that the plane deletes every version under
  `sessions/<id>/` and records the device in the tombstone's `applied_by`. After the
  device rather than at the erasure, because the device is the only writer: a deletion
  before it had stopped could be followed by the segment it was uploading. By the plane
  rather than the daemon, which is where this departs from the issue's wording: the issue
  took the objects to be reachable only by the daemon, and the plane holds the
  object-storage credential it signs with (390). `ObjectStore.Signed` keeps deletion off a
  daemon on purpose, and a presigned `DELETE` per version would let a person destroy their
  own session's ciphertext outside an erasure. Only for an erased session of the caller's
  own, since saying a session is erased does not erase it. Every device is told until it
  acknowledges, since any of them may hold a copy; the second one finds nothing left to
  delete.
- **A device that never comes back.** Its key is gone, so the objects are unreadable to
  anybody, the plane included, and they stay until one of the owner's devices connects:
  the deletion is tidiness, as `Erasure` says of a pod's. The copy on that machine is on
  the person's own disk, which no erasure reaches.
- **A team session is unchanged**: handed to a healthy pod of its profile, or left for
  the next one to enrol, and its key is never the plane's to touch.
