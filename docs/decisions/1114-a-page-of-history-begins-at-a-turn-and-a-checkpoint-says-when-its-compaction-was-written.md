---
number: 1114
title: "A page of `session.events` begins where a turn does, after the root's rest or at seq 1, trimmed to the first rest in it or reaching back over a turn longer than the page up to 5,000 events; a checkpoint carries `compacted_at`, the time of the compaction it follows, which readers show as when the summary was made"
date: 2026-11-26
status: accepted
issue: 1193
supersedes: [1094, 1095]
paths:
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/session/checkpoint.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/packages/client/src/opening.ts
  - clients/tui/lib/troupe/remote/translate.ex
symbols:
  - Troupe.events_before/3
  - Troupe.Session.Checkpoint.data/1
  - fromCheckpoint
gist: "session.events page starts after a root rest (Checkpoint.rest?) or at seq 1: mid-turn raw page trimmed to after its first rest; none but its last = reach back to the turn's rest, cap 5,000 (then cut); reads one event before the page; checkpoint gains optional compacted_at (the compacted event's ts), shape stays session/1, absent = the checkpoint's ts"
---

Issue #1193. Narrows Decision 1094 (`session.events` answers at most `limit`, the
checkpoint's fields) and Decision 1095 (the `earlier` entry says when the checkpoint was
written). A page cut where the count fell could begin in the middle of a turn, so a reply
was drawn without the person's line until the next page came; and the summary's time was
the rest after the compaction, which can be a long turn later.

**The server cuts at a turn.** `Troupe.events_before/3` reads the event before the raw
page too. Where that is the root's rest (`Checkpoint.rest?/1`: `turn_ended`, `cancelled`,
`agent_done`, an interrupted restart) or the page starts at seq 1, the page is as asked.
Otherwise it starts after the first rest in it but its last; where there is none, it
reaches back a window at a time, each twice the last, to the rest the turn began after or
seq 1. So a page is never empty and the next, asked before its first seq, ends at a rest.
The cap is 5,000 events, ten of the largest page: a single answer stays a bounded read
and frame, and a turn longer still is answered in pieces that long, cut where the count
falls. A client holds nothing back, since nothing is cut.

**The compaction's own time.** `Checkpoint.data/1` writes `compacted_at`, the `ts` of the
root `compacted` it follows, beside the checkpoint's own `ts`. The desktop, the console and
the terminal show it as when the summary was made. `shape` stays `session/1`: the field is
not a fact and a checkpoint without it reads as before, the reader taking the checkpoint's
own `ts`; the recorded logs in `test/fixtures/checkpoints/` are kept as such checkpoints.

## Not chosen

- The client holding a cut turn until its head arrives: every reader would carry it, and
  a reader that pages once would never draw the reply.
- Trimming a page with no rest down to nothing: a turn longer than the page could never
  be paged past.
- No cap: one turn of a runaway loop would be one answer of the whole log.
- Bumping `shape`: every checkpoint already written would be replayed past.

## If undone

A page back can open on a reply with no question above it, and the summary says when the
root next rested rather than when it was made.
