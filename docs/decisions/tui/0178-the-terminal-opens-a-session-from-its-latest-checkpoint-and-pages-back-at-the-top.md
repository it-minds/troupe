---
number: 178
title: "A session this machine holds nothing of opens from its latest checkpoint: the summary as the window's first block, the facts folded in, the tail after it; PgUp or Home at the top pages the history in above it; the journal keeps the checkpoint's events, so a reattach resumes from the cursor"
date: 2026-11-23
status: accepted
issue: 1183
paths:
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/remote/journal.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/client.ex
gist: "Empty journal + checkpoints capability: subscribe {from: checkpoint}; Translate.checkpoint seeds :earlier (summary block, usage, goal, todos, loop) + rest + open asks at through; unknown shape = new socket from 0; PgUp/Home already at the top: session.events 500, history refolded and drawn above, row kept; journal keeps the seed, never the history"
---

Issue #1183, on root Decision 1094. The worker subscribed from the journal's cursor, 0 on a
first attach, and the window folded every event before it showed.

**Open.** With an empty journal and a server naming `checkpoints`, the worker subscribes
`{from: "checkpoint"}`. A checkpoint in the answer becomes local events at its `through`
(`Translate.checkpoint/3`): one `:earlier`, which draws the summary as the transcript's
first block ("Earlier · summarised at" the checkpoint's time, the words behind the prose
rail, capped as prose is and whole with `e`) and sets what the window keeps (usage, goal,
the root's tasks, a running loop); the root at rest as the facts say; and each open
approval and question as the event that asked it. Then the replay after `through` folds on
top. The block is a turn of its own. No checkpoint, or no capability, opens as before. A
shape this client does not read drops the socket and subscribes from 0 on the next.

**Journal.** It keeps those events, not the facts raw: a reattach draws the same window
from disk and subscribes from the cursor, asking for nothing again, as Decision 76 asks of
a remote session. Re-asking the checkpoint would cost a round trip and a second contract.

**Page back.** PgUp or Home with the view already at its top asks `session.events {before:
the lowest seq folded, limit: 500}` off the screen's process; the scroll title says
"loading earlier…" and the hint line "PgUp loads earlier" while there is more. Every page
is folded again with the pages before it, so a call a page boundary cut is one entry, and
each agent's history entries are replaced by that fold's above the block; scalars stay the
live fold's. The view keeps its row; turns `e` opened keep theirs. `more: false` ends it.
History is never journaled.

## Not chosen

- A sparse journal holding pages: it assumes contiguous seqs and a max-seq cursor.
- Loading on reaching the top by scrolling: a stray PgUp would fetch 500 events.

## If undone

A long session's first open in the terminal folds its whole log again before the window
shows, and the summary of what it folded is drawn nowhere but as "context compacted".
