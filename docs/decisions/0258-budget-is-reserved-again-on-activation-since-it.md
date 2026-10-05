---
number: 258
title: Budget is reserved again on activation, since it is released on dormancy
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/team_budget.ex
gist: Budget is reserved again on activation, since it is released on dormancy
---

Otherwise a woken session would run on no reservation at all. `start_elsewhere`
reserves the session's own slice — its terms', or the default — after placing and
before pushing, and a team with nothing left cannot wake a session any more than it
can create one. Reserving twice for one session is a retry in `TeamBudget`, so a
session whose slice was never released is unaffected.
