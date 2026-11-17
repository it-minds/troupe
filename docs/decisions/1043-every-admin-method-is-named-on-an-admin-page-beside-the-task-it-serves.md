---
number: 1043
title: Every admin method is named on a page under docs/admin/ beside the task it serves, and a plane test fails naming any that is not
date: 2026-11-17
status: accepted
issue: 1018
paths:
  - docs/admin/
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
gist: A new %Method{} in Admin.API needs its name on the admin page for its task; an exemption is listed in the plane's coverage test with its reason
---

**The decision.** Every method `Troupe.Plane.Admin.API` declares is named, in backticks and
in full (`admin.team.admin.remove`, never "`add` / `remove`"), on the page under
`docs/admin/` where an administrator does the task it serves: the routine step on
`routine-tasks.md`, the console area's row on `console.md`, a key's rotation on
`security.md`. A sentence or two each, saying what it answers or changes; the arguments
and the full answer stay in PROTOCOL.md's generated table (Decision 1035), not repeated.

A plane test reads the method names from `API.list/0`, the same declarations the reference
task renders, and fails naming each method no file under `docs/admin/` mentions. A name
inside a longer one does not count (`admin.team.unlink` inside
`admin.team.unlink.preview`). A method that should be on no admin page is listed in the
test with a one-line reason, never skipped silently; the list is empty today.

**Not chosen.** Counting PROTOCOL.md's table as coverage: it is generated from the methods,
so it always covers them and says nothing about whether the task pages do; 21 methods were
in it and on no admin page, all eight memory methods and `admin.signing.rotate` among them.
Requiring the console's map (`Troupe.Plane.Admin.Console`) instead: it proves a screen
calls the method, not that the pages say so.

**If undone.** A method lands with only its generated row, and an administrator reading the
task pages never learns it exists, as happened to the signing key's rotation, whose warning
(every machine that pinned the old key refuses what the new one signs) was on no page.
