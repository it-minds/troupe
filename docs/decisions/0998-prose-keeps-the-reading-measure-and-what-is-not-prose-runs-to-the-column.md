---
number: 998
title: "In the desktop app a frame is as wide as what is in it, from the reading measure up to the session's column: prose keeps the 78ch measure, and a code block, a diff, a table and a call's output run to the column before they scroll sideways inside their frame"
date: 2026-11-15
status: accepted
issue: 936
supersedes: [877]
paths:
  - clients/gui/apps/desktop/src/styles.css
gist: "Frames fit their content between the 78ch measure and the column; prose words stay at 78ch, code, diffs, tables and tool output widen to the column, then scroll in the frame"
---

Issue #936, after #935 widened the session's column to 1200 px on a wide window. Decision
877 drew every frame at the reading measure, so the column widened and the troupe's code
did not: a diff wrapped or scrolled at about 750 px on a monitor that had room for it. This
supersedes that one sentence of 877, that a frame is held to the measure; the rest of 877
stands, and Decision 999 takes what else of it #659 changes.

**The rule.** A frame is `width: fit-content` between `min(100%, 78ch)` and the column.
Prose is held to the measure where it is words: a reply's paragraphs, headings, lists,
quotes and rules each keep `max-width: 78ch`, so a reply of sentences is a frame of the
measure, as before, and the same reply with a wide listing in it widens to show the
listing while its paragraphs stay where they were read. A block inside prose spans its
prose frame. A call's frame runs to the column, and what came back sits in a frame that
fits it the same way. A body wider than the column scrolls sideways inside its own frame,
as it did inside the measure. Reasoning and the strip are words and keep the measure; a
prose frame's source view is the Markdown as written and keeps it too.

**Not chosen.** A wide frame for every reply, with the words held to the measure inside
it: a reply of two sentences would sit in a 1200 px box mostly empty, which reads as a
layout fault. A width per kind (code wide, prose narrow) set on the frame: a reply is one
prose frame that holds its blocks, so the kind that decides is the block's, and a frame
has to follow what is in it.

**Proof.** `apps/desktop/test/code-frames.test.tsx` reads the rules from the stylesheet,
since jsdom lays nothing out; on the branch's base the frame rule held `max-width:
var(--measure-reading)` and failed. Walked in the pane at 1280 and 1920 wide with a
session holding prose, code, a diff, a table and a Mermaid block (`pnpm fake`'s parser
session): at 1920 the answer's frame was 1141 px, the whole of the reply's column (the
1200 px column less the reply's byline gutter), its diff and table 1107 px, its paragraphs
750 px, and a reply of one sentence a frame of 750 px; at 1280 the reply's column is
701 px, narrower than the measure, the frame fills it, and the diff scrolls inside its
frame with no sideways scroll on the page.
