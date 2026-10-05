---
number: 725
title: An activation that fails takes away the log and the workspace it put on the pod, and leaves what it found there; a read and a fork name an unreachable store or key manager as an activation does
date: 2026-09-29
status: accepted
issue: 259
paths:
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/lib/troupe/worker/session/reader.ex
  - apps/troupe_worker/test/troupe/worker/reader_log_test.exs
gist: An activation that fails takes away the log and the workspace it put on the pod, and leaves what it found there
---

Issue #259. An activation restores the session's
log into the pod's state directory, then its workspace, then starts the sealer and
the actor tree. A failure after the log was written (storage that stopped answering
at the workspace listing, which Decision 722 made a failure; a config the session
would not start with; a raise on the way) left the log and the workspace until the
session was next activated on that pod or went dormant there, which for a session
that goes on to run on another pod is never. `Manager.put_back/3` now removes them on
any such failure, returned or raised. It removes only what the activation added. A
log that was there before it started is a reader's, restored for `session.read` and
perhaps still served, and a workspace with anything in it is one a pod that stopped
without putting the session to sleep left, which may hold files no archive has: both
stay, and a failure before the events step touches nothing. The pod's cache is
sealed bytes the activation only read and stays too, with 722's rule that it is
used only once storage has answered unchanged. `session.read` and the fork step of
`session.activate` opened their contexts and read storage without the names
Decisions 721 and 722 gave an activation, and answered `internal_error` with the
inspected transport error. They now go through `Restore.open_context/2` and
`Restore.unreachable/2`, answer `unavailable` with `object_store_unreachable` or
`kms_unreachable` and the endpoint or address, and say so in the pod's log, which
for a read is the only place: the plane hands the client an endpoint whatever the
pod answered. Proof: `failed_activation_test.exs`, and the read and fork cases in
`object_store_unreachable_test.exs` and `kms_unreachable_test.exs`.
