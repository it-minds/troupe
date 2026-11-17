---
number: 1010
title: A pod session asks when its budget is spent, as a laptop session does, unless its terms set a turn or wall-clock limit; the platform's switches and `approvals` are not limits
date: 2026-11-16
status: accepted
issue: 986
supersedes: [660]
paths:
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/test/troupe/worker/unattended_session_test.exs
  - apps/troupe_core/test/troupe/agent/budget_question_test.exs
  - apps/troupe_core/lib/troupe/config/schema.ex
  - PROTOCOL.md
  - docs/user/sessions.md
  - docs/admin/bundles-and-triggers.md
gist: budget_asks is false only when the terms set max_turns or wall_clock_ms, never because terms came; a waiting root sleeps like an idle one
---

Amends the pod paragraph of Decision 660 and nothing else of it: a spent budget is still a
question, `full_send` still never asks, a subagent still never asks, and a limit somebody
wrote into a session's terms is still a contract that stops.

**What was wrong.** 660 had the worker set `budget_asks: false` "whenever the plane's
terms set anything at all", and `Restore.contract/1` read that as "the terms list is not
empty". It is never empty: the plane sends the platform's two `managed_*` switches with
the terms on every placement, so absent means off. Every pod session therefore ran its
budget as a contract, and a shared session started from the desktop with no limits in its
terms ended `budget_exhausted` on the first message after its wall clock ran out, with
everything written after it dropped as `input_after_done`. Defect D32 had noted the
leftover in September.

**The rule.** `contract/1` decides from the limit keys, `max_turns` and `wall_clock_ms`
(the plane's `wall_clock_seconds`), not from the list's length:

- **Terms that set neither** leave `budget_asks` at its default, true. The session asks
  the person attached exactly as on a laptop: `budget_ask_started`, the owner or anyone
  with control answers, input queues as `input_queued` meanwhile. `:terms` is still set,
  to no caps, which is what tells the question it runs on the platform (no workspace
  scope).
- **Terms that set either** keep 660's contract: `budget_asks: false`, and the session
  stops at whichever of its limits is reached first, `agent_done` `budget_exhausted` as
  before. The caps still ride along as `:terms`, so nothing an answer did could raise past
  them (699).
- **`approvals: deny`** is not a limit. A session under it asks, and the questions
  server's unattended mode answers no on the spot, so it ends `budget_exhausted` with the
  question and the no in its log, as 660 said for an unattended session.
- **`full_send`** is unchanged: it never asks.
- `budget_micros` is the plane's ledger, not the agent's budget, and is not touched.

The managed switches stay where they are, appended to the terms by `with_managed/2`:
`contract/1` no longer counts them, and a second channel for "configuration this session
did not choose" would be one more thing to keep in step.

**Nobody attached.** The question waits in `Troupe.Session.Questions`, the agent
`waiting`, as on a laptop whose client went away. The worker's idle timer used to treat a
`waiting` agent as busy, so a pod with nobody there would have stayed awake on the
question for good. It now sleeps on the usual schedule as an idle one does: nothing runs
until somebody answers, the question is in the log, and the agent that wakes asks it again
under the same id (660's fold), so the first client to attach finds it.

**Not chosen.** A term of its own (`budget: ask | stop`) that the plane would send, as D32
suggested: it adds a field to the wire, the trigger form and the console for a choice the
limit keys already make. A trigger that wants a hard stop writes a limit; one that does not
has nobody to stop for.

**Proof.** `Troupe.Worker.UnattendedSessionTest`: terms of the switches alone give
`budget_asks: true` and no caps, `max_turns: 5` with them gives `false` and the cap; a spent
budget with no limit in the terms asks, the session goes dormant on its idle timer with the
question owed, and wakes to the same question, whose answer carries the turn on; under
`approvals: deny` the question is answered no and the session ends. `Troupe.Agent.BudgetQuestionTest`:
a pod-shaped root (the switches, no caps) asks, and input sent meanwhile is queued, not dropped.
