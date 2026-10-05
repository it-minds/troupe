---
number: 45
title: Every reservation is written before it is granted
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/ledger/reservation.ex
  - apps/troupe_plane/lib/troupe/plane/team_budget.ex
gist: Every reservation is written before it is granted
---

That is what makes respawning
on a survivor safe: the new actor reloads from PostgreSQL and reads back exactly what
was handed out. A reservation that lived only in a process would be lost with the
replica that made it, and the next actor would hand the same slot out again.
