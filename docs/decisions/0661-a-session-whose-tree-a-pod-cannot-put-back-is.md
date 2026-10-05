---
number: 661
title: A session whose tree a pod cannot put back is parked read-only, once, rather than left `active` for every client that opens it to fail on
date: 2026-09-20
status: accepted
paths:
  - PROTOCOL.md
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/test/troupe/worker/kms_unreachable_test.exs
  - apps/troupe_worker/test/troupe/worker/object_store_unreachable_test.exs
  - apps/troupe_worker/test/troupe/worker/unrestorable_test.exs
gist: A session whose tree a pod cannot put back is parked read-only, once, rather than left `active` for every client that opens it to fail on
---

Treating every refused
activation the same way — `dormant`, and try again next time — is a loop when the
directory is gone, with a raw error for whoever clicked each time. So the worker
names the class: `Restore.start` failing with `{:not_a_directory, path}` answers
the plane's `session.activate` push as `not_found` with `data.reason:
"workspace_gone"` (`Commands.activation_error/1`), and — because the client-driven
path, a pod activating lazily when somebody attaches, never answers a push — the
manager also reports it as a `session.unrestorable` notification
(`Manager.unrestorable_report/2`, only for that class; a stale epoch or storage
that did not answer is still the plane's to retry or refuse). On the plane both
roads end in `Sessions.unrestorable/2`: the row goes `read_only`, off its worker,
fenced on the epoch like a status report so a pod on an older epoch cannot park a
session a newer one serves, and saying it about a session already parked, erased or
unknown changes nothing. The slot and the budget slice go back as they do at
dormancy. `read_only` is the honest state — history readable, nothing activates it
again — and it already refuses activation with `forbidden` before any pod is asked,
so the failure happens once and then never.
