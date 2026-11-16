---
number: 1011
title: The wall clock counts working time, each turn from its start to its end with waits on a person left out; a restart forgives the time worked except what a question about it recorded
date: 2026-11-16
status: accepted
issue: 985
paths:
  - apps/troupe_core/lib/troupe/budget.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/agent/headroom.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tools/ask_user.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/test/troupe/budget_test.exs
  - apps/troupe_core/test/troupe/agent/budget_question_test.exs
  - apps/troupe_core/test/troupe/agent/headroom_test.exs
  - PROTOCOL.md
gist: wall_clock_ms is time worked, not time awake; rest and waits on a person stop the clock; a restart keeps only a question's used
---

**What was wrong.** `Troupe.Budget` started its clock when the agent process started and
`elapsed/1` was the monotonic time since, idle included. On a laptop the default 30 minutes
roughly matched one sitting. On a pod the agent lives as long as the pod keeps the session
awake, and a shared session people come back to is awake for hours, so the first message
after minute 30 found the clock spent, though nobody had worked for most of it.

**The rule.** The clock counts time the agent spends working.

- `Budget` keeps `worked_ms`, the stretches of work so far, and `working_since`, when the
  one under way began. `work/1` starts it, `pause/1` adds the stretch and stops it, both
  idempotent; `elapsed/1`, `used/2`, `check/1`, `slice/2` and the headroom read the total
  with the stretch under way.
- The agent starts the clock where a turn starts (`start_turn` once the gate lets it
  through) and where a compaction starts, and stops it where a turn ends (rest, the wait
  for a background child, a cancel, `done`) and where it stops at the gate to ask the
  budget's or the failure guard's question.
- A call waiting on a person stops it too. The tool task that asks for an approval
  (`Tools.ask`), `ask_user`'s question, and a delegation held at the approval gate tell
  their agent before and after (`Server.waiting_on_person/3`); the agent keeps the calls
  waiting in `person_waits`, the clock stands still while any is, and runs again when the
  last is answered, if the agent is still thinking, acting or compacting. An agent passes
  each of these up to its parent, so a root waiting on a subagent that waits on a person is
  not working either. A turn's start and end clear `person_waits`, so a task killed
  mid-wait cannot hold the clock still for longer than its turn.
- The question's text and `budget_warning`'s `detail` name it: `working time 24m/30m (80%)`.

While several calls run and one of them waits on a person, the clock stands still for all
of them: the turn is waiting on somebody, and a clock that ran on the others would charge
a person's reading time to whichever tool happened to be slow beside it.

**On restart.** The time worked is forgiven: a restarted agent's clock starts from nothing,
as it did before, when the process's start was the clock's. Replaying it would need the
log to carry each turn's working time, a new field on `turn_ended`, `cancelled` and
`agent_done`, which this does not add. The one exception is what the log already says: a
`budget_ask_started` about the clock carries `used`, and replay keeps at least that much,
so a question about the clock owed when a session went to sleep is still owed when it
wakes, asked again under its id rather than waved through by a fresh clock.

**What does not change.** A trigger's `wall_clock_seconds` is still the longest its run may
work: an unattended run has no idle time and waits on nobody under `approvals: deny`, so it
meets the limit where it did. A subagent's slice of the clock is a share of what its parent
has left of working time, as before. The words a client shows for a stop (#987) are the
client's; `agent_done` and `budget_exhausted` are unchanged on the wire.

**Proof.** `Troupe.BudgetTest` ("the wall clock"): idle past the limit is not exhausted,
working past it is, stretches add and the time between them does not, starting a running
clock and stopping a stopped one change nothing. `Troupe.Agent.BudgetQuestionTest`: resting
between turns spends none of it; time waiting on the budget question does not count; an
approval a subagent waits on counts for neither it nor the root; a restart keeps a
question's `used` and asks again; the question names `working time`. `Troupe.Agent.HeadroomTest`:
the gauge reads the time worked and the detail says `working time`.
