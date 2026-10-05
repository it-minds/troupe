---
number: 290
title: A call no gateway named gets `seq:<session>:<n>`, and reconciliation calls it `unmetered`
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_gateway
gist: A call no gateway named gets `seq:<session>:<n>`, and reconciliation calls it `unmetered`
---

A log written before costs were recorded has real tokens and no
cost. It is still recorded, because the tokens are real; it gets a synthesised id,
because the ledger's uniqueness is what makes re-folding safe; and the id has a
shape no gateway would mint, so the nightly job can count it as a cost that was
never captured rather than as a call billed twice. Unmetered rows are not drift and
do not make a comparison dirty.
