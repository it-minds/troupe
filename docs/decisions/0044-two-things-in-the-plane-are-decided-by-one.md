---
number: 44
title: Two things in the plane are decided by one process, not by a lock
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/singleton.ex
  - apps/troupe_plane/lib/troupe/plane/placement.ex
  - apps/troupe_plane/lib/troupe/plane/team_budget.ex
gist: Two things in the plane are decided by one process, not by a lock
---

Capacity per
profile and budget per team are both read-decide-write, and two replicas doing
either at once is exactly how you overbook. Each is an actor registered with
`:global`, so the question is serialised by a mailbox; callers on other replicas
reach it by name. When the node holding one dies, `:global` forgets the name and the
next caller starts it on a survivor.
