---
number: 288
title: No price table
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/reconcile.ex
gist: No price table
---

The gateway prices the call before it answers, and
`Troupe.Plane.Reconcile` already exists to catch the ledger disagreeing with it.
A price of our own would reconcile against itself, and keeping a table of model
prices current is a job somebody has to do forever. Where the gateway reports no
cost, the tokens are recorded with a cost of zero rather than an estimate.
