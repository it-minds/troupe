---
number: 693
title: "A subagent is stopped once its parent has its result, and a restart closes what it leaves behind: the calls of a child nothing starts again, a turn's results already back, and a root's note about a failed request"
date: 2026-09-26
status: accepted
issue: 171
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
gist: "A subagent is stopped once its parent has its result, and a restart closes what it leaves behind: the calls of a child nothing starts again, a…"
---

- **Stopped on report (#171).** A finished subagent kept its process, and with it its
  whole conversation, until its session's tree stopped. Nothing addresses a finished
  child by its process. Input, a cancel, the loop, the watcher and an approval's
  answer go to the root. `read_branch` reads branches, which are sessions, off disk.
  The TUI's agent detail and the desktop app build an agent from events. A restart
  replays the root's own log, and a delegation it takes up again gets a new child
  (688). `Troupe.snapshot/2` and `Troupe.agent_tree/1`, which the worker's drain and
  the sleep rule (#166) walk, take a stopped child for what a `:done` one was, not
  at work. So the parent stops the child's Node as soon as it has taken the result,
  through its own `Agent.Children` as a cancel does. An idle time first would keep the
  memory for nothing. The child writes `agent_done` and announces `done` before it
  reports, so its parent's `tool_call_completed` always follows its `agent_done`, and
  stopping it cuts nothing off.
- **An unpriced model's warning (689)** was claimed in the registry by the agent whose
  call it was, and the claim went with that agent: a subagent that stops would have
  left the next one to warn again, once a delegation. The session's `Log` now makes
  the claim, and it lives as long as the tree.
- **A delegation a restart closes or takes up again (D18, D19).** Nothing starts its
  child again, so the child never reports and never closes its own calls. After the
  session came back, an approval it had waited on stayed open in `Summary`, the
  worker's status and the desktop app's transcript (a test confirmed it), and its log
  had no `agent_done`. The parent now writes, under that child and every agent below
  it, a `tool_call_completed` with `ok: false` for each call still open, which is how
  every reader already closes an approval or a question (#142, #145) and the per-call
  half of what a cancel writes (#138). Then `agent_done`, with the new reason
  `interrupted`, where the agent has none.
- **A turn a restart comes back in the middle of (D19).** The results that were back
  before it were not put back. The next `tool_results` held only the calls re-run or
  closed, which a provider refuses (every `tool_use` is owed a `tool_result`), and a
  `finish` among them lost its summary and took another model turn. Replay now puts the
  completed calls back from their `tool_call_completed`, with the summary of a `finish`
  among them, when the restart re-runs or closes the rest; one that takes nothing up
  leaves them, so a summary cannot outlive its turn (688).
- **A root's failed request (D19).** "The previous model request failed: ..." went
  into the conversation and not into the log, so the conversation a restart rebuilt
  did not have it. It rides in the `llm_error` as `note`, and replay folds it. Not a
  `user_input` from the harness, as the other notes are: a client reads one of those
  as the turn going on, and the A2A mapping would turn a failed task back to
  `working`, while this note ends the turn.
