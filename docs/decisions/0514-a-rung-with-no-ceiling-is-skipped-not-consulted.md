---
number: 514
title: A rung with no ceiling is skipped, not consulted
date: 2026-09-16
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/*budget.ex
gist: A rung with no ceiling is skipped, not consulted
---

The platform rung is one
actor for the whole deployment summing the entire ledger, and consulting it on
every create when it has no ceiling timed fifty concurrent creates out. Absence
means everything; this makes a rung with no opinion cost nothing to ask. The team's
rung is always consulted — it is the ceiling people actually set, and its actor is
per team rather than per deployment.
