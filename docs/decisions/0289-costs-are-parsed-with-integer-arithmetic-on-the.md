---
number: 289
title: Costs are parsed with integer arithmetic on the digits, never a float
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane
gist: Costs are parsed with integer arithmetic on the digits, never a float
---

`8.87 * 1_000_000` is `8869999.999999999` in binary floating point. One unit per
call is a ledger that does not add up, and a ledger that does not add up is worse
than one that is missing rows, because nobody can tell which number is wrong.
Truncation beyond six places, because that is what a micro-unit column holds.
