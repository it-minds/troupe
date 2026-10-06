---
number: 732
title: A reader takes the log it restored with it, and stays while a client reads the session; a fork whose parent's workspace listing fails makes no child
date: 2026-09-29
status: accepted
issue: 269
paths:
  - apps/troupe_core/lib/troupe/events.ex
  - apps/troupe_protocol/lib/troupe/sessions/fork.ex
  - apps/troupe_protocol/lib/troupe/sessions/storage.ex
  - apps/troupe_protocol/test/troupe/sessions/storage_test.exs
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/test/troupe/worker/object_store_unreachable_test.exs
  - apps/troupe_worker/test/troupe/worker/reader_log_test.exs
gist: A reader takes the log it restored with it, and stays while a client reads the session; a fork whose parent's workspace listing fails makes no child
---

Issue #269.
`session.read` restores a dormant session's log into the pod's state directory, and
nothing removed it: it stayed, in plaintext, until the session was next activated on
that pod and put to sleep there. The reader now removes it when it stops, however it
stops: its last follower gone, closed, idle, or the pod shutting down. Not a log that
was there before the read (725's rule for an activation, from the other side), and not
one an activation has: a manager registered for the session, whether it is starting
over the log or running, or one that has written to it since, which the reader tells
by the log no longer being the size it wrote, a log only growing. Such a log may hold
events storage does not have yet. A restore writes the log and a reader removes it
under one lock per session on the pod (`Restore.with_log/2`), so an activation that
starts as a reader leaves is either seen by it or writes its log after. Taking the log
away made the reader's lifetime matter: a client reading through the pod's harness
reads the log from disk and follows no process, and a reader that went after its 30
seconds would take the log from under them. So a reader stays while a client is
attached to the session (`Troupe.Events.attached?/1`) or an activation is starting,
and goes once one has taken the log over; the cost is a process and the log on the
pod for as long as somebody reads. One case is left as before: an activation that
wrote the log again with a longer history and then failed, which by its size is not
the reader's. On the fork's side, `Storage.workspace_archives/2` read a failed listing
as no archives, so a fork that met storage going away at that one request sealed a
child with the parent's history and no tree, and the child, having segments, was never
forked again: 722's failure for an activation, in the fork. A failed listing now fails
the fork before anything is written for the child, as `object_store_unreachable` where
it was the network's, and the plane tries again; `workspace_at/3` says the same, and
`Fork.copy/3` is its only caller. Proof: `reader_log_test.exs`, the fork case in
`object_store_unreachable_test.exs`, and `storage_test.exs`.
