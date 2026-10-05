---
number: 147
title: Reconciling is by gateway request id and nothing else
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_operator
gist: Reconciling is by gateway request id and nothing else
---

It is the only identifier
both systems share; reconciling by timestamp and amount would make two identical
calls a second apart indistinguishable.
