---
number: 253
title: Terms become config overrides at the pod
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_worker
gist: Terms become config overrides at the pod
---

`max_turns` is the budget's
`max_turns`; `wall_clock_seconds` becomes `wall_clock_ms`, which `Budget` already
exhausts on; `approvals` is `:deny` when it says so and the default otherwise.
There is no `auto` a trigger can ask for, which is the design's refusal written
into the parser.
