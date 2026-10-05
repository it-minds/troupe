---
number: 678
title: "A session has a goal: an event to set it, an event to clear it, and a section of the root agent's prompt on every turn in between"
date: 2026-09-22
status: accepted
issue: 59
paths:
  - apps/troupe_core/lib/troupe/session/loop.ex
gist: "A session has a goal: an event to set it, an event to clear it, and a section of the root agent's prompt on every turn in between"
---

It is in the harness so every
client gets it. `session.goal.set {text}` and `session.goal.clear` are activating
commands with `control` scope, like `profile.switch`; the root agent writes
`goal_set` (`text`, `command_id`) or `goal_cleared` under the actor who asked, and
folds them like the task list, so the goal survives a crash, a dormancy and a
resume. `session.goal.get` is read from the log and wakes nothing. The events are
spelled like every other durable event (`goal_set`, not issue #59's `goal.set`: the
dotted spelling is the older vocabulary clients still translate, never one the
harness writes); the methods keep the issue's names. The goal goes into the system
prompt as a `<goal>` section, rebuilt for each request between the skills and the
task list, rather than as a message in the conversation: the prompt is already
composed fresh on every request for exactly this kind of standing context (the
project brief, the task list), and a message would be summarised away by the next
compaction and repeated into the log on every turn. It is taken at once in any
state, not postponed to the turn boundary as a profile switch is, because it only
changes what the next request says. Only the root agent carries it: a subagent is
handed a task by an agent that knows the goal. Setting the goal a session already
has, or clearing one it has not, writes nothing. The fold's witness gains a `goal`
key only while one is set, so every recorded fixture folds to the hash it always
did. The TUI's `/goal` sets, shows and clears it and its status line carries it.
Proof: `Troupe.Agent.GoalTest`, the goal tests in `Troupe.Gateway.DaemonTest`, and
the TUI's `Troupe.GoalClientTest`.
