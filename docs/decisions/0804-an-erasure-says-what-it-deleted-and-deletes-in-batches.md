---
number: 804
title: An erasure reads every delete's answer and deletes a thousand versions to a request; a version the store keeps leaves the device or pod unrecorded and told again, and the plane answers a daemon's `session.erased` within its call and finishes a longer deletion after it
date: 2026-10-06
status: accepted
paths:
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_gateway/test/support/fake_plane.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/test/troupe/plane/private_erasure_test.exs
  - apps/troupe_protocol/lib/troupe/object_store.ex
  - apps/troupe_protocol/test/support/object_store_case.ex
  - apps/troupe_protocol/test/support/object_store_stand_in.ex
  - apps/troupe_protocol/test/troupe/object_store_deletes_test.exs
  - apps/troupe_protocol/test/troupe/object_store_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
  - apps/troupe_worker/test/troupe/worker/erasure_test.exs
  - docs/admin/routine-tasks.md
symbols:
  - Troupe.ObjectStore.delete_prefix/3
  - Troupe.Plane.Erasure.device_applied/2
gist: Erasure deletes go 1,000 per DeleteObjects; a refused one leaves the device or pod unrecorded and told again; session.erased answers within 5 s
---

D71, its first two items; Decisions 756, 786 and 789. `ObjectStore.delete_prefix/3`
sent one `DELETE` per listed version, dropped each answer and returned how many it had
listed, and both erasures go through it: a pod's (`Storage.erase/2`, which the pod's
`session.erase` answered as carried out whatever it returned) and the plane's of a
private session (`Erasure.device_applied/2`, inside the daemon's `session.erased`
call). On the chunk's tip a version under a legal hold, in an object-lock bucket of the
development MinIO, was counted with the others: `{:ok, 3}` with it still there, the plane
answering `objects_deleted: 2` and recording the device, a pod recorded in the
tombstone's `applied_by`, so nothing ever tried again. And a private session with 20,000
versions held the plane's answer to `session.erased` for more than two minutes, against
the fifteen seconds a daemon waits for one (`Troupe.Gateway.Plane`).

- **Every answer read, and a refusal reported rather than counted.** `delete_prefix`
  answers `{:ok, count}` only when every version is gone, and otherwise `{:error,
  {:not_deleted, %{deleted:, left:, reason:}}}`: how many went, the versions still there
  and the first reason. It does not stop at the first refusal (the slot allowed either):
  a hold or a policy refuses one version and says nothing of the next, so the rest go,
  which leaves a retry only what is really left. A request the store does not answer, or
  fails as a whole (a 5xx, a transport error, a 403 to a whole batch), does stop it, with
  what was not sent left too: the next request would fare the same, and each could take
  a request's whole sixty seconds to say so. A version the store says it no longer has
  (`NoSuchKey`, `NoSuchVersion`) is gone, as a single delete's 404 already was.
- **A thousand to a request.** S3's `DeleteObjects` (`POST ?delete`), quiet, so the
  answer names only what it did not delete, with the `Content-MD5` S3 requires, and the
  keys escaped for XML as a listing's are unescaped. A store with no batch delete (501,
  405 or `NotImplemented`) has the rest go one `DELETE` at a time, where a 4xx refuses
  that version and anything else stops it. The listing is still whole before the first
  delete (786): deleting while paging would start the next page after a marker that is
  gone.
- **Not erased yet means told again.** No new state. A private session's `erased` and
  `erasure_pending` are about its key (756), which is gone by the time its objects are
  deleted, and the session coming back as `erasure_pending` would say the key is still
  there. What stays pending is the acknowledgement, which already drives the retry: the
  plane records a device in the tombstone's `applied_by` only once nothing is left, so
  `session.erasures` names the session to it again at its next link and its
  `session.erased` tries again. Meanwhile it answers `unavailable` with `objects_deleted`
  and `objects_left`, and the daemon's log says the plane has not deleted the objects yet
  rather than that it was not told. A pod's `session.erase` answers `unavailable` the
  same way, so the plane does not record the pod and `pending_for/2` hands the erasure to
  the next pod of the profile to enrol, which reports `session.erased` only for one it
  carried out. That is how the slot's "the session stays `erasure_pending`" is met: the
  erasure stays pending for that device or pod, and the session's state says what its
  key does.
- **Within the call, then after it.** `device_applied/2` deletes in a task under
  `Troupe.Plane.Erasure.Tasks` and waits for it as long as the call can be answered
  within: `:erasure_answer_ms`, five seconds by default, a third of the daemon's fifteen.
  Done by then, the answer is `deleting: false` with the count, as before. Not done, it
  is `deleting: true` with no count, and the task carries on and records the device when
  nothing is left, or logs what it could not delete and leaves the device to be told
  again. Chosen over deleting batches until a budget runs out and leaving the rest to the
  next link, which, links being hours apart, would take a large session many of them to
  finish; and over always answering at once, which would say nothing of what happened
  where a session goes in a second, as most do. A task on a replica that stops leaves the
  device unrecorded, so its next link starts again; two acknowledgements at once delete
  the same prefix twice, and the second finds what the first left, as a second device's
  always has.
- **Not in this:** a team session's erasure goes to a pod at the erasure and otherwise
  only at an enrolment, so one a pod was refused stays pending until a pod of its profile
  next enrols, and erasing it again does not try again as it does for a private session.
  And a pod's `session.erase` still answers carried out where its key was not destroyed
  (`key_destroyed: false`), which the plane records as done.
- **Proof:** `ObjectStoreTest`, against the development MinIO: a version under a legal
  hold in an object-lock bucket is left and said to be, the two beside it go, and once
  the hold is lifted asking again finishes it; `{:ok, 3}` on the tip. `ObjectStoreDeletesTest`,
  against a stand-in S3 on loopback: 2,500 versions go in requests of 1,000, 1,000 and 500
  and no single `DELETE`; a store answering `NotImplemented` has them go one at a time; a
  503 and a dropped connection are each reported with nothing deleted; a batch failed as a
  whole stops the next, with 1,500 left; and a quiet answer's `NoSuchVersion` counts as
  deleted and its `AccessDenied` does not. The plane's `PrivateErasureTest`: a private
  session with 20,000 versions is answered in 4.8 seconds with every one gone and the
  device recorded (on the tip the call was still deleting when the test's database
  ownership ran out at two minutes); a held version answers `unavailable` with one deleted
  and one left, the device unrecorded and named again, and once the hold is lifted the
  next acknowledgement finishes it (on the tip, `objects_deleted: 2` and recorded); and
  with no wait at all the answer is `deleting: true`, the task's refused deletion leaves
  the device to be told again, and after the hold is lifted it is recorded. The worker's
  `ErasureTest`: a pod refused one object is not recorded, the erasure is still pending
  for the profile, and the pod's next enrolment finishes it and is recorded (on the tip it
  was recorded at once).
