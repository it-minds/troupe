---
number: 804
title: An erasure reads every delete's answer and deletes a thousand versions to a request; a version the store keeps leaves the device or pod unrecorded and told again, and the plane answers a daemon's `session.erased` within its call and finishes a longer deletion after it
date: 2026-10-06
status: accepted
paths:
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_protocol/lib/troupe/object_store.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/lib/troupe/worker/plane/link.ex
symbols:
  - Troupe.ObjectStore.delete_prefix/3
  - Troupe.Plane.Erasure.device_applied/2
gist: Erasure deletes go 1,000 per DeleteObjects; a refused one leaves the device or pod unrecorded and told again; session.erased answers within 5 s
---

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
  rather than that it was not told. A pod's `session.erase` answers `unavailable` the same
  way, so the plane does not record the pod and `pending_for/2` hands the erasure to the
  next pod of the profile to enrol, which reports `session.erased` only for one it carried
  out.
- **Within the call, then after it.** `device_applied/2` deletes in a task under
  `Troupe.Plane.Erasure.Tasks` and waits for it as long as the call can be answered
  within: `:erasure_answer_ms`, five seconds by default, a third of the daemon's fifteen.
  Done by then, the answer is `deleting: false` with the count, as before. Not done, it is
  `deleting: true` with no count, and the task carries on and records the device when
  nothing is left, or logs what it could not delete and leaves the device to be told
  again. Chosen over deleting batches until a budget runs out and leaving the rest to the
  next link, which, links being hours apart, would take a large session many of them to
  finish; and over always answering at once, which would say nothing of what happened
  where a session goes in a second, as most do.
