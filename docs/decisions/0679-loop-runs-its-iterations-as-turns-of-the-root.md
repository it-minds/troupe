---
number: 679
title: "`/loop` runs its iterations as turns of the root agent, not as subagents; each ends with the agent's verdict as a tool call; and a loop the whole session came back from is stopped, not resumed"
date: 2026-09-22
status: accepted
paths:
  - ARCHITECTURE.md
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/loop.ex
  - apps/troupe_core/lib/troupe/registry.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/loop.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tools/goal_complete.ex
  - apps/troupe_core/test/troupe/session/loop_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - docs/developer/architecture.md
gist: "`/loop` runs its iterations as turns of the root agent, not as subagents; each ends with the agent's verdict as a tool call"
---

An iteration is an input to the root agent from `loop`, on
the root's own conversation, with the goal already in its prompt (678). A subagent
per iteration was the other way, and it is worse at what a loop is for: it starts
from nothing and reports only a summary, when what the earlier iterations tried and
what failed is exactly what the next one needs; it carries no goal (678 gives it to
the root alone); its budget is a slice of the root's; and the person watching sees a
delegation instead of the work. The root's turns already have approvals, the budget
question, compaction and cancelling, and an iteration may still delegate. The
verdict is `goal_complete {summary}`, offered on the loop's turns and no others, and
outside the profile's tool list because it changes nothing but whether the loop goes
on; the loop reads the completed call from the log and never the model's prose. An
iteration without one is followed by the next. The loop is `Troupe.Session.Loop`, a
process in the session's tree below the agent, which writes `loop_started`,
`loop_iteration_started`, `loop_iteration_finished` and `loop_stopped` under the
root's path and folds what it wrote with the function a replay uses
(`Troupe.Loop`), so a live loop and a replayed one cannot disagree. It stops on the
goal, at `loop_max_iterations` (10), after `loop_max_failures` (3) failed iterations
in a row, when the budget question is asked (the question stays with the person, and
an `allow` does not restart the loop), on `turn.cancel`, on a cleared goal, and on
`session.loop.stop`, which cancels the root's turn only if it is the loop's. The
agent is told which loop it serves and drops an iteration of any other, so one queued
behind a person's turn cannot run after the loop stopped. The loop process
restarting inside a live session carries on, closing an iteration nobody saw end as
`failed`; the whole tree coming back marks the loop `interrupted`, for the reason an
interrupted session makes no model call (ARCHITECTURE.md §2.4), and
`resume_on_restart` opts back in. Proof: `Troupe.LoopTest`, `Troupe.Session.LoopTest`,
the loop tests in `Troupe.Gateway.DaemonTest`, and the TUI's `Troupe.LoopClientTest`.
