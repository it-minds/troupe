---
number: 1095
title: "The desktop and the console open a session from its latest checkpoint where the server has the capability, its summary a quote at the top and the history paged in above it on Earlier; the replay up to the subscription's head is folded at once and set once, and the desktop lays a turn out again only when it changed"
date: 2026-11-23
status: accepted
issue: 1182
paths:
  - clients/gui/packages/client/src/opening.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/src/session.ts
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/frames.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/anchor.ts
  - clients/gui/apps/console/src/views/Remote.tsx
symbols:
  - TranscriptFeed
  - fromCheckpoint
  - withEarlier
  - layout
gist: "subscribe {from: checkpoint} where the server names checkpoints; the transcript starts from the facts with an `earlier` entry (the summary, a quote) and the open approvals and questions; Earlier pages session.events (500) above it, the reader's place kept; replay held to head_seq and folded once; layout kept per turn"
---

Issue #1182. Narrows Decision 877 (`layout`) and Decision 986 (the session view). A
10,000-event session took five to seven seconds to open in the desktop: each replayed event
was its own render, and each render laid out every turn.

**Folded at once.** `TranscriptFeed` holds the stream until the subscription's `head_seq`
is reached, then folds it in one update, each event with the time it arrived; after that,
each event as it comes. A replay that stops short is folded once nothing has come for
300 ms. The state is the one-at-a-time fold's, which the recorded logs prove.

**From the checkpoint.** Where `initialize` names `checkpoints`, the first subscription asks
`from: "checkpoint"`. `fromCheckpoint` maps the facts to the fold's scalars, draws an
`earlier` entry (the summary, under "Earlier" and when the checkpoint was written) and the
approvals and questions still open, and the tail folds on top. Facts in a shape it does not
know give the summary alone. No checkpoint, or no capability: from seq 1, as before.

**Paging back.** Earlier at the top asks `session.events` before the first seq drawn, 500 at
a time. Every page so far is folded again from empty and drawn above the `earlier` entry,
so a call one page started and the next ended is drawn ended; answers in the tail to a call
before the checkpoint are kept and folded onto each page. The history gives entries only,
never the head's facts; the open approvals and questions are drawn once, in the tail. The
first entry on screen stays where it was (`holdPlace`); a live line still goes under the
tail and scrolls there.

**Laid out once per change.** `layout` keeps each turn's result and hands back the same
objects unless its entries, level, budget stop, following note or, while a call of it
runs, the clock changed; a turn is drawn by a memoised `TurnGroup`, so a tick redraws the
running strip and the curtain line.

Not chosen: windowing the transcript (paging and the checkpoint bound what an open draws;
left to measure on sessions that rarely compact); fetching the pages on scroll (a press is
explicit, and the scroll position is the reader's); keeping the history's scalars (they are
the checkpoint's).

If undone, a long session opens by drawing every event it ever wrote, once per event.
