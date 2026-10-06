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

Issue #171, and D18 and D19 in
docs/developer/defects.md.
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
  `finish` among them lost its summary and took another model turn. Replay now puts
  the completed calls back from their `tool_call_completed`, with the summary of a
  `finish` among them, when the restart re-runs or closes the rest; one that takes
  nothing up leaves them, so a summary cannot outlive its turn (688). A call closed
  as interrupted and one put back out to a person now reach the conversation in one
  `tool_results`, not two.
- **A root's failed request (D19).** "The previous model request failed: ..." went
  into the conversation and not into the log, so the conversation a restart rebuilt
  did not have it. It rides in the `llm_error` as `note`, and replay folds it. Not a
  `user_input` from the harness, as the other notes are: a client reads one of those
  as the turn going on, and the A2A mapping would turn a failed task back to
  `working`, while this note ends the turn.
- **Old logs** have no `note` and no `interrupted`, and replay as they did.
  `Troupe.Log.Fold` counts a `note` as a message, and the recorded fixture hashes are
  unchanged.
- **Proof:**
  - `Troupe.Agent.DelegationTest`: five delegations with one still at work hold that
    one alone (the agent tree and the registered processes counted), five in a row
    hold none, and a stopped child is still read from its log, before and after its
    parent restarts; each child's `agent_done` comes before its result is taken.
  - `Troupe.Agent.ResilienceTest`: a restored session leaves no approval of its
    subagent open, in `Summary` or the gate; the child a restart re-ran a delegation
    past ends `interrupted` with nothing open; a root's failure note survives the
    session coming back; a turn keeps the results already back when the session comes
    back, a call closed as interrupted and one put back out to a person reach the
    model together, and a `finish` among them ends a root, and a subagent with the
    summary its parent is handed, after the agent restarts.
  - `Troupe.Agent.CutShortTest`: a subagent cut short is stopped, and its session
    still sleeps. `Troupe.Session.LocalPricingTest`: a model only subagents call is
    said once a session. `Troupe.Log.FoldTest`: the fixture hashes, unchanged, and
    the note.
  - The installed daemon, driven with a fake-provider script.
- **Not done here:** a subagent a cancel takes down still leaves its own calls open in
  its own log; the `cancelled` on the agent above closes them for every reader (#145).
