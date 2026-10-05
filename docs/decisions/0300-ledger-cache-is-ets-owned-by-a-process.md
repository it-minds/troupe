---
number: 300
title: "`Ledger.Cache` is ETS owned by a process, invalidated by the only writer"
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/ledger/cache.ex
  - apps/troupe_plane/lib/troupe/plane/team_budget.ex
gist: "`Ledger.Cache` is ETS owned by a process, invalidated by the only writer"
---

Sums
over an append-only table get slower every day. `TeamBudget` is already one actor
per team and is the only thing that inserts, so the invalidation is serialised
without a lock; a cache that is not running answers by computing, which is what a
test and a `mix` task get. Only a batch that inserted something invalidates —
a replaying pod must not cost every panel a fresh aggregate.
