---
number: 27
title: Worktree finishes commit with a fixed `troupe` identity (`-c user.name=troupe`)
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Worktree finishes commit with a fixed `troupe` identity (`-c user.name=troupe`)
---

A user's checkout may have no git identity configured; the commit lands on the `troupe/` branch only and the user's merge commit carries their own identity.
