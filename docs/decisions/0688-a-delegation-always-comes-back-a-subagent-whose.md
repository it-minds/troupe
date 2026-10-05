---
number: 688
title: "A delegation always comes back: a subagent whose model request fails hands its parent what it has, a child's path names one child for the life of the session, and a `finish` ends only the turn that called it"
date: 2026-09-25
status: accepted
issue: 149
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
gist: "A delegation always comes back: a subagent whose model request fails hands its parent what it has, a child's path names one child for the life of…"
---

Issue #149, three defects found by
fixers in the chunk before 0.5.0, in the family of its gate on runaway and hung
agents. Two left a parent waiting on its `delegate` call for ever, since a delegation
has no timeout; the third ended a turn before the model saw its results.
- **A failed model request.** A root rests after one (685): the error goes into its
  conversation and the person says what next. A subagent rested too, and nobody
  talks to a subagent but its parent, which was waiting on it. It now ends
  `llm_error`, as a spent budget (660) or a failing tool (687) ends it, and hands its
  parent what it said before the failure, labelled cut short, or a line saying the
  request failed before it reported anything. Either way the error is in it, so the
  parent's model can tell a blown context from a gateway that is down before it
  delegates again. A context overflow still compacts once and retries first.
  `llm_error` joins `agent_done`'s reasons; a root never ends with it, and its
  `turn_ended` keeps no `reason`, since the `llm_error` before it says why and the
  clients already read that.
- **A child's path.** `spawn_child` names a child `<agent>#<n>` from `child_seq`,
  which was never folded, so after any restart the next delegation was `#1` again.
  A child started under a path that has a log replays that log instead of taking its
  task; the first child had finished, so the new one came back `done`, never
  reported, and its parent waited. `delegation_started` is now folded, to the highest
  number a child path ends in. Not a count: a child that failed to start took a
  number and wrote no event. A path from before the numbers (`["root", "explore"]`)
  counts as one more. A delegation that a restart takes up again, being a call that
  had not finished (re-run at least once, as any tool is), gets a new child on the
  same task rather than the path it had: that child's log would come back `done` if
  it had reported just before its parent died, and hang as before. What the old
  child did is still in the log.
- **`finish`.** Its summary waits for the turn's other calls, and was never cleared.
  After a finished root was woken (635), or a cancel stopped a turn with a `finish`
  in it, the next tool turn finished at once with the old summary. It is now cleared
  with the rest of a turn's call bookkeeping, in `State.clear_calls/1`.
- **Old logs.** `Troupe.Log.Fold` witnesses `delegation_started` without projecting
  it: the children it started are in the witness already, each an agent under its
  own path, so the recorded fixture hashes stand and a change in how paths are made
  would still move them.
- **Proof:**
  - `Troupe.Agent.DelegationTest`: a subagent whose model request fails, after
    saying something and before.
  - `Troupe.Agent.ResilienceTest`: a second delegation after an agent restart and
    after the session comes back, a delegation a restart takes up again, a woken
    agent's tool turn, and a `finish` in a cancelled turn.
  - `Troupe.Log.FoldTest`: the fixture hashes, unchanged, and the witness.
  - The installed daemon, driven with a fake-provider script.
