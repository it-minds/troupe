---
number: 593
title: "`money/1` reads a zero as \"no ceiling\", so a spend is never rendered through it"
date: 2026-09-17
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/web/live/layout.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/budgets.ex
gist: "`money/1` reads a zero as \"no ceiling\", so a spend is never rendered through it"
---

A ceiling and a spend are different quantities and only one of them means
something by being absent: a team that had spent nothing read `unlimited / 500.00
this period`. So `figure/1` is the plain number, `money/1` keeps its opinion for
ceilings, and `amount/1` — whose every caller is a spend or a reservation — renders
through `figure/1`. A test walks three screens and fails on `unlimited` in any
amount.
