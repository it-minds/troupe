---
number: 760
title: The desktop app shows a team session whose turn the harness stopped as failed, and says why in words
date: 2026-10-03
status: accepted
issue: 354
paths:
  - apps/troupe_core
gist: The desktop app shows a team session whose turn the harness stopped as failed, and says why in words
---

Issue #354, defect D53's first bullet, following 745 and 750.
- **A plane's row is read for its reason.** `rowFromPlane` maps `failed_reason` to
  `FleetRow.failed` as `{reason, detail: null}`, the field a daemon's rows fill (745),
  so the list's row, the launcher's and the review queue's status say Failed for a
  team session as they do for a local one, and nothing that reads `failed` has a new
  shape to learn. `detail` is null because a plane holds no content (750). A plane
  from before the column, or a row without one, says nothing failed.
- **Each reason has its words.** `failedTitle` says "The agent kept crashing and the
  session stopped" for `agent_failed`, as before, and "A tool kept failing and the
  harness stopped the turn" for `tool_failures`: the failure guard counts one tool's
  failures in a row, so it is a tool and not the agent. A reason the app does not know
  reads "The turn failed (<reason>)" rather than nothing.
- **A local session still cannot say `tool_failures`.** The daemon's `failed` is
  `agent_failed` only (745), so those words reach a local row only once a daemon lists
  it, and the transcript still shows such a turn as the failure guard's question
  answered `stop`, as 745 left it. A notification that reads a row's `failed` follows,
  though a plane's rows count nothing unseen and so raise none.
- **Proof:** the client's `fleet` test (a plane row with each reason, one with none,
  one from before the column) and the desktop app's `team-failed` test (a fake plane
  lists a session stopped on each reason beside one that finished; the launcher's
  recent rows and the list say Failed, with the reason's words on hover), both failing
  on the tip; and the web build against `pnpm fake`, which now seeds a run stopped on
  `tool_failures`.
