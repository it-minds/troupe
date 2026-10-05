---
number: 114
title: A headless run whose turn the failure guard stopped ends `1`, and the budget question's `a` lifts the one limit it names
date: 2026-09-25
status: accepted
paths:
  - clients/tui
gist: A headless run whose turn the failure guard stopped ends `1`, and the budget question's `a` lifts the one limit it names
---

The daemon now stops a turn in which one
tool has failed ten times in a row, asking the person attached first (root Decision
687). Headless mode answers that question as it answers any, with the first option,
which the daemon makes `stop`; the turn then ends with `turn_ended` carrying
`reason: tool_failures`, which the translation passes on and the printer reads as a
stop short, so a script or a nightly job sees `1` and the reason rather than a `0`
for a run that did nothing. The window's budget line names the limit and says that
`a` lifts it for the session, because since 687 that is all `always` does. Proof: the
CLI test with a model that reads a missing file twelve times, and the translation
test.
