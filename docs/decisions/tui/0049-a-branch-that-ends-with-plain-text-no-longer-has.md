---
number: 49
title: A branch that ends with plain text no longer has its whole final message repeated as the `finished (…)` line
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: A branch that ends with plain text no longer has its whole final message repeated as the `finished (…)` line
---

A text response with no `finish` call ends the branch with that text as the summary, so the transcript printed it twice; the fold now prints the bare `finished (finished)` when the summary is exactly the message above it.
