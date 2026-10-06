---
number: 25
title: Profile switching on a finished (`:done_unread`) branch is written straight to the log by the Dispatcher
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Profile switching on a finished (`:done_unread`) branch is written straight to the log by the Dispatcher
---

The branch has no live process at that point (Decision 6); the fold applies the new definition when the branch is continued, which is exactly the plan-then-build flow.
