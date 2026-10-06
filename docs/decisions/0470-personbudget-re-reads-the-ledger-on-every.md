---
number: 470
title: "`PersonBudget` re-reads the ledger on every decision rather than caching what has been spent"
date: 2026-09-16
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/person_budget.ex
  - apps/troupe_plane/lib/troupe/plane/team_budget.ex
gist: "`PersonBudget` re-reads the ledger on every decision rather than caching what has been spent"
---

Charges arrive through the *team's* actor, so a per-person total kept
in this process would drift the first time one landed. One query per session create
is not a hot path, and this is the lesson the placement actor already taught at a
cost: a count held in a process and never reloaded is a count that is permanently
wrong from the first thing it did not see. `TeamBudget` reloads on reserve too, for
the same reason.
