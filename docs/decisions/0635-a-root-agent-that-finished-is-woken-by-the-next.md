---
number: 635
title: A root agent that finished is woken by the next input
date: 2026-09-19
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/loop.ex
  - clients/tui/lib/troupe/remote/translate.ex
gist: A root agent that finished is woken by the next input
---

The two reasons for
being done are not alike. Budget exhaustion is a limit the person set, and asking
again does not raise it, so that case writes `input_after_done` and nothing
happens. `finished` is the model's own opinion that it was done, and the person's
next message is exactly the evidence that it was not. So a root agent in `:done`
with `done_reason: :finished` takes input as a new turn on the same conversation —
the `finish` call already has its `tool_results` there, so the model owes nothing
and the turn is well-formed — after writing `agent_woken {from, source}`, which the
replay fold and `Log.Fold` read to clear `done_reason`; without that, a restart
would bring the agent back `:done` with a conversation that had moved on. Subagents
are not woken: theirs is a report to a parent, and the parent is what a person
talks to. The worker's lifecycle needs nothing new — `agent_state` already carries
`done_reason`, and the woken agent's first `thinking` clears it on the plane's row.
