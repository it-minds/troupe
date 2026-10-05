---
number: 722
title: A workspace is restored from what storage says it has, or the activation fails; a key manager the pod cannot reach is `kms_unreachable`; the worker image watches with `inotifywait`
date: 2026-09-29
status: accepted
issue: 252
paths:
  - apps/troupe_core/lib/troupe/session/files.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/test/troupe/worker/kms_unreachable_test.exs
  - apps/troupe_worker/test/troupe/worker/workspace_listing_test.exs
gist: A workspace is restored from what storage says it has, or the activation fails; a key manager the pod cannot reach is `kms_unreachable`
---

Issue #252. The restore reads the events and then finds the
workspace's newest archive by listing `workspace/`, and a listing that failed was read
as "no archive": the session came back with an empty tree, or with an older one from
the pod's cache, under a history that had moved past it, and its next archive sealed
that over the newer one. A failed listing now fails the activation, as
`object_store_unreachable` when it was the network's (Decision 721), and the plane
tries again. The cost is that a pod whose cache is current cannot use it while
storage does not answer; a cache is only trusted once storage has said it is not
behind, which is the rule the cache already had. A transport error from
`Context.open` is `{:kms_unreachable, address, reason}`, answered as `unavailable`,
for the reason 721 names the store: the bare error said neither which host nor that
it was the key manager. The worker image installs `inotify-tools` (GPL-2.0, a
separate program the VM starts, as `git` is; the licence inventory lists lock files,
and Debian keeps the package's licence in the image), so `Troupe.Session.Files` on a
pod reports a deletion, inside a second; and where `inotifywait` is installed but
refused or stopped, as on a node whose inotify limits are used up, `Files` polls
rather than going quiet, as the session watcher already did. Proof:
`workspace_listing_test.exs`, `kms_unreachable_test.exs`, core `files_test.exs`, and
the worker image with a session deleting a file.
