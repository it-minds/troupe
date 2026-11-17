---
number: 1026
title: The console has no owed list and no not-built page; every administrative method the plane serves is called from a screen, and one the plane adds fails the console's coverage test until a screen calls it
date: 2026-11-17
status: accepted
issue: 1029
supersedes: [912]
paths:
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/apps/console/src/views/Shell.tsx
  - docs/admin/console.md
gist: No owed.ts, no Unbuilt page, no built flag; a method the plane serves without a screen here fails coverage.test.ts
---

Every area of the console's map had a screen, and `owed.ts` had been empty since Decision
912, yet the file, its two shape tests, the "not in this console yet" page and the rail's
mark for it stayed, and one test asserted the list was empty while the file's comment said
methods go there. This replaces the part of 912 that kept the file "as the place a method
the plane adds before its screen is drawn is listed", and narrows 892 and 904, which held
the console to "reached from a screen or listed in `owed.ts`": now it is reached from a
screen, with no second way to pass. An address that names no area of the role's map opens
where the role starts, as it already did; the screen fallback is a one-line "no such page"
that no address reaches. 912's other parts (rules edited as rules, a profile taking its
channel's servers) stand.

- **Not chosen.** Keeping `owed.ts` empty and deleting only the test that said so: a list
  nobody writes to, a page nobody reaches, and a way for a new method to ship with no
  screen and a green test.
- **If undone.** A method the plane adds can be parked in a list and the console reports
  itself complete without a screen for it, which is the gap the coverage test exists to
  close; bring back an owed list only with its page, its mark and one test that agrees
  with them.
