---
number: 848
title: The sessions index never waits on a session; its sweep asks from a task and decides from the answers, a stop runs in a task of its own, a session being stopped reads as dormant until its tree is gone, and a read is answered from a task
date: 2026-10-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/test/troupe/sessions/index_test.exs
symbols:
  - Troupe.Sessions.Index
gist: Nothing in the index's process calls a session or reads a log; probes, stops and reads run in its tasks, and a stopping session is hidden and never stopped twice
---

D117 in `docs/developer/defects.md`. `Troupe.Sessions.Index` put sessions to sleep from
inside its own process: every fifteen seconds it asked each live session, one at a time,
whether a client was watching it (`Watcher.enabled?`) and what its agent was doing
(`Troupe.snapshot`, and for one waiting on a person its approvals, questions, subagents
and tasks), and stopped the ones due with `Troupe.stop_session`. A stop is
`DynamicSupervisor.terminate_child` with a thirty-second shutdown. Every read was answered
inside the same process too: a listing read every log on disk and asked each live session's
summary and log. So any of those could keep the index busy past its callers' timeouts (five
seconds for `get` and `live_ids`, fifteen for `list` and `recent_workspaces`), and every
caller behind it timed out. That was the shared cause of most `Sessions.Index` call
timeouts in D8, and a daemon with many sessions would stall the same way.

- **The sweep asks from a task and decides here.** Each tick starts one task, under a
  `Task.Supervisor` the index starts beside itself, that asks each live session in turn
  what this process used to ask it, in the same order (attached, watched, the agent's
  state), and sends each answer back as a message as soon as it has it, so an answer is as
  fresh when it is acted on as it was. The index folds the answer into the entry's two
  clocks and decides from them, exactly as before. A tick that finds the last sweep's task
  still asking starts none, so a session that is slow to answer delays the next sweep and
  nobody's call.
- **A stop runs in a task of its own.** A session that is due is marked `stopping` in its
  entry and `Troupe.stop_session/1` runs in a task. The entry stays until the session's
  monitor says its tree is gone, which is what drops it, as it always did for a session that
  crashed. A stop that fails (an exit, or the session not found) clears the mark and starts
  the idle clock again, so the next sweep looks at it afresh.
- **The order is kept by the mark.** While an entry is `stopping`, no sweep asks about it or
  stops it, and no read sees it as live: `live_ids` leaves it out, and `get` and `list` read
  it from its log, as `:dormant`, which is what they would say a moment later. Two sweeps
  cannot stop the same session twice: a sweep decides only on an answer about an entry that
  is not marked, and the mark goes only with the entry or with a stop that did not happen.
- **A read is answered from a task.** `get`, `list` and `recent_workspaces` take a copy of
  the entries this process holds as it is asked (the ones being stopped left out) and the
  state directory, and a task reads the logs and the live sessions' summaries and replies to
  the caller. The messages and the replies are what they were, so a caller holding a private
  index (the tests do) is unchanged. `live_ids` is a map lookup and stays here. Reads are not
  queued behind one another: a `get` does not wait on a slow listing. The cost is that two
  listings at once read the disk at once; they did the same work before, one after another,
  with every other caller waiting behind them.

What did not change: when a session is due (the two clocks, Decision 707's reader rule, a
person's question as nothing to do), what a stop does (`session_dormant`, then the tree down
through `Troupe.Sessions`), and the calls' timeouts. Left as they were, and worth a later
look: an agent that does not answer its snapshot in five seconds counts as gone and its
entry is dropped while its tree runs; `Troupe.Sessions.stop_session/1` runs the whole
shutdown inside the `Troupe.Sessions` process, so a slow stop still holds up every other
session's start and stop there, though no longer anybody's call to the index; and a
listing still reads every log on disk, so on a state directory with thousands of session
directories one `list` can take longer than its own fifteen seconds. It now does so alone.

Proof: `apps/troupe_core/test/troupe/sessions/index_test.exs`. One test holds a session's
stop for six seconds with a child that takes that long to terminate; on the tip before this
change `live_ids` timed out, and now `live_ids`, `get` and `list` each answer in well under
a second, say the session is not running, and the session is stopped exactly once (one
`session_dormant`) through dozens of sweeps. The other suspends one live session's summary
and shows a `get` of another session answering at once, where before it waited five
seconds behind it.
