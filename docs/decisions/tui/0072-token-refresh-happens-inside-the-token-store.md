---
number: 72
title: Token refresh happens inside the token store process, blocking it for the round trip
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/tokens.ex
gist: Token refresh happens inside the token store process, blocking it for the round trip
---

Two connections reconnecting at once then make one refresh between them instead of two, and every caller waiting on a stale token wants the same answer anyway. A refresh happens at most once every several minutes; the alternative (refresh outside the process, reconcile afterwards) buys nothing and can mint two tokens.
