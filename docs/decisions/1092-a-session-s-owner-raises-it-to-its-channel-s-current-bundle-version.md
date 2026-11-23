---
number: 1092
title: "A pod session's owner raises it to its channel's current bundle version, in place on its pod when it is at rest and at its next wake when it sleeps; the pin moves only once a pod started it there, and the move is `config_upgraded` with `reason`, `by` and `by_name`"
date: 2026-11-23
status: accepted
issue: 1177
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - clients/gui/packages/client/src/bundle.ts
  - clients/tui/lib/troupe/client/bundle.ex
symbols:
  - Troupe.Worker.Session.Manager.restart/3
  - Troupe.Plane.Sessions.owe_raise/3
gist: "session.bundle.raise: owner, current version only, never lower; dormant at next wake, running via session.restart (tree restarted on its pod at rest, kept for the root's rest); pin moves on the pod's acceptance; config_upgraded reason/by/by_name; root told once in turn context"
---

Issue #1177. Narrows Decision 125: its "the only way a session's configuration ever moves is
a deliberate upgrade at activation, when the version it was pinned to has been retired"
gains "or when its owner raises it, in place when at rest, at the next wake when asleep".

**The method.** `session.bundle.raise {session_id}`, `control`, the owner or a holder of the
owner role, as archiving. The target is the profile's channel's current version, never
another and never lower. Refused: a session on a computer, a pending or read-only one,
nothing published (`conflict`), a gone grant (`forbidden`), and a target that does not
offer the agent the session runs as (`invalid_params`, `agent`, the target's `agents`, as a
create checks it, Decision 979). Already current answers the row. One audit row.

**The raise is owed until a pod takes it** (`bundle_raise_to`, `bundle_raise_by`). A wake's
pin treats it as the retire path does, with `reason: raised` and who. A running session is
pushed `session.restart`: with no agent of the tree working (`interrupted` is at rest) the
pod stops the tree without the dormancy marker and starts it again over its own log and
workspace on the new pin; the sealer and every subscription follow the session's id and
stay. Busy, the pod keeps it and applies it when the root next reaches idle or done, and
the plane answers `conflict` with the status. A tree that does not come back sleeps, and
the next wake applies it. The pin moves only on the pod's acceptance (`activated/3`, the
restart's answer, the status report's `bundle_version`); the retire path's re-pin before
the push went too. The row records `bundle_channel`, backfilled from the profile's.

**The log and the model.** `config_upgraded` gains optional `reason`, `by`, `by_name`, one
writer (Decision 1029). The root folds it and says it once in a `configuration` turn-context
section (Decision 863). A command an attached client sends during the restart waits on the
manager, as during a wake.

## Not chosen

- A hot swap at a turn boundary: skills are a mount and definitions the tree's.
- Sleeping and waking the session: it would cut a turn and might move it to another pod.
- A `bundle_raised` event: a second writer of "the configuration moved".
- A `to`, or lowering: a rollback is a republish followed by a raise.

## If undone

A session stays on its version until it is retired, and a person who wants a newer agent
starts again without the conversation. Without the pin moving on acceptance only, a failed
start leaves the row naming a version the session never ran on.
