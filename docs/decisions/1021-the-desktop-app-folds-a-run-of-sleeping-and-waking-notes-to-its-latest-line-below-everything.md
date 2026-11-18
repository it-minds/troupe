---
number: 1021
title: "The desktop app folds a run of sleeping and waking notes to its latest line below `everything`"
date: 2026-11-17
status: accepted
issue: 1001
paths:
  - clients/gui/apps/desktop/src/frames.ts
symbols:
  - layout
  - LIFECYCLE_NOTES
gist: "Below everything, consecutive session_dormant, session_activated, session_resumed and agent_restarted notes are drawn as the run's last line; everything draws all"
---

Issue #1001. Each wake of a pod session writes four notes: `session_dormant`,
`agent_restarted` (with how many events it replayed), `session_resumed` and
`session_activated`. A session that had slept twice between two turns opened with eight
of them, and a long-lived one buried its conversation under them.

`layout` now hides each of these notes when the next drawn entry is one of them too, at
`quiet` and `tools`. A run of them is then one line, the latest, which says where the
session stands. At `everything` all of them are drawn, as the rest of the working is,
so a bug report still has them. The set is `LIFECYCLE_NOTES` in `frames.ts`. Notes that
need a person (a model error, a budget, a failed agent, an input after done) are not in
it and are never folded, and neither is anything `docs/design/frames.md` section 5 keeps
open.

The fold is the view's, like the rest of `layout`: the transcript still holds every
entry, and nothing is written to the session's log. The terminal UI draws them all still;
the frames page says so, and bringing it the same fold is its own change.
