---
number: 750
title: "On a plane, a turn the harness stopped is a failed turn: the row says why, the run is failed and its target is told, and a pod whose session stopped under it puts it to sleep then"
date: 2026-10-01
status: accepted
issue: 320
paths:
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/session.ex
  - apps/troupe_plane/priv/repo/migrations/20261001000750_session_failed_reason.exs
  - apps/troupe_worker/test/troupe/worker/stopped_turn_test.exs
  - clients/gui/apps/desktop/src/views/bits.tsx
  - clients/gui/apps/desktop/test/team-failed.test.tsx
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/packages/client/src/plane.ts
  - clients/gui/packages/client/test/fleet.test.ts
  - clients/gui/packages/client/test/support/plane.ts
  - clients/gui/scripts/fake-deployment.ts
gist: "On a plane, a turn the harness stopped is a failed turn: the row says why, the run is failed and its target is told, and a pod whose session…"
---

Issue #320, defect D47, following 687, 727 and the daemon's `failed`
(745).
- **The worker reports `failed_reason`.** `turn_ended`'s `reason`, `tool_failures`
  (the failure guard's `stop`) or `agent_failed` (a root that crashed as often as it
  may be restarted), goes into `session.status` and the dormancy report beside
  `done_reason`, from that `turn_ended` until the root's next `user_input`; an
  activation reads it back from the log as it reads `interrupted`. The words are the
  event's. The turn's end also rests the root in the report, because a root that
  crashed sends no `agent_state` after it. A field and not a new `status`, for 745's
  reason.
- **Not 745's `failed`.** The daemon's `failed` is `{reason, detail}`, for
  `agent_failed` only, and `detail`, the first line of what the agent raised, is
  content, which a plane never holds. A string under its own name carries the reason
  alone, for both stops, and no key a client reads changes shape between a daemon and
  a plane.
- **The plane keeps it** on the session row, set whenever a report carries the key,
  as `done_reason` is, and lists it in `sessions.list` and a run's listing. A run
  whose session has one is `failed`, awake or asleep (it read `running`, then
  `created`), and holds no place under its trigger's concurrency cap. The status page
  calls the row broken even asleep, since a root that kept crashing is always asleep
  after it; the review queue and the runs table name the reason.
- **`notify_url` is posted the outcome, read from the row.** A report with a reason
  announces the run as `done` and `interrupted` do. The body's `state` is the run's
  state as a listing gives it, `done` or `failed`; it was the worker's status, so an
  `interrupted` run now says `failed`. `done_reason`, which the body named and was
  never given, is filled, and `failed_reason` is beside it.
- **The manager watches its tree.** A tree that stops by itself (727) was noticed only
  when the idle timer next looked, ten minutes on: the slot and the budget slice held,
  and an activation answered `ok` for a session that was not there. The manager now
  monitors the session it started and puts it to sleep when it stops, sending first a
  report the debounce held, since that is the one that announces. The cost is folded
  from the log left on the pod, because the projection that knew it went down with
  the tree and the dormancy report said `0`.
- The desktop app's team rows don't read `failed_reason` yet.
- **Proof:** the worker's `stopped_turn_test.exs` (a tool that fails ten times with
  nobody to ask; a root that keeps crashing, asleep within seconds with its cost; the
  same session woken, saying so until a turn starts) and `approval_status_test.exs`
  (the fold over a recorded log), and the plane's `triggers_test.exs` (a pod's report
  makes the run failed, on the row and in the post, with no place under the cap; a
  crashed session asleep is failed and broken, and told once). Each failed before
  this change.
