---
number: 1094
title: "A `checkpoint` event follows each root compaction, written by the session tree at the root's next rest, its facts the fold of the log up to that rest; a cache in the chain that a reader may start from and that one not knowing its shape replays past"
date: 2026-11-23
status: accepted
issue: 1181
paths:
  - apps/troupe_core/lib/troupe/session/checkpoint.ex
  - apps/troupe_core/lib/troupe/session/checkpoints.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/sessions/fork.ex
  - apps/troupe_protocol/lib/troupe/sessions/sealer.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
symbols:
  - Troupe.Session.Checkpoint.fold/2
  - Troupe.latest_checkpoint/1
  - Troupe.events_before/3
gist: "checkpoint {shape session/1, through, compacted, previous, summary, facts}: one per root compaction, at the root's next rest, by Session.Checkpoints (last in the tree, a failed fold writes none); facts = fold to through, cache, unknown shape = replay from 1; fork shifts its seqs; subscribe {from: checkpoint} + session.events (500) under the checkpoints capability; seal reports checkpoint_seq, the plane keeps it"
---

Issue #1181. Every reader of a long session folded it from seq 1; `compacted` rebuilds the
agent's conversation but says nothing of the session, nor which range it folded.

**One per root compaction, at rest.** After a root `compacted`, the session's
`Session.Checkpoints` (last in the tree, after `Summary`, subscribing before it replays)
appends `checkpoint` under the root when the root next rests: `turn_ended`, `cancelled`,
`agent_done`, or a restart that leaves its turn interrupted. Then nothing of the root's is in
flight. A compaction a crash left without one is owed and written at the next rest, the tree
coming back at rest included. A subagent's compaction writes none, and nothing writes one on
a timer. `compacted` gains `folded_through`, the head when the summariser was asked. The
writer is the session tree's, the one writer of its log, so the event is chained and, on a pod
or for a private session, sealed like the rest.

**What it carries.** `shape` (`session/1`), `through` (the rest), `compacted`, `previous`,
the summary as the compaction wrote it, and `facts`: `Troupe.Session.Checkpoint`'s pure fold
of every agent's events to `through` (PROTOCOL.md lists them). Never a title, pin, archive,
presence, unseen mark, anything of a viewer or of "now", nor a blob's, artifact's or
document's content; a context window is not in the log, so not in the facts. The contract:
the facts plus the fold of the events after `through` equal the fold of the whole log,
held by a property test and by recorded logs every client suite reads.

**Cache.** A reader that does not know `shape` replays from seq 1, and a change of what a fact
means raises it; later events fold on top. A fork moves every seq a carried checkpoint names
by one, as it moves `log_repaired.event`. The writer starts from the latest checkpoint too.

**Reading.** Under the `checkpoints` capability, `subscribe {from: "checkpoint"}` answers the
checkpoint and `from_seq` and replays after `through` (from 0 with none); `session.events
{before, limit}` (at most 500) pages back. Both seek through the log's offsets, the
checkpoint found back from the head a doubling window at a time. A seal report names
`checkpoint_seq`, which the plane keeps on the row.

## Not chosen

- Writing it inside the compaction: mid-turn the root's calls and spend are open, and the
  facts are the session's, which only a projection of the whole log holds.
- The agent's own restore from it: a second contract, where a wrong budget overspends.
- Dropping a carried checkpoint on a fork: the child would replay everything.

## If undone

Every reader folds from seq 1 again, and the clients' loading from a checkpoint (#1182, #1183)
has nothing to start from.
