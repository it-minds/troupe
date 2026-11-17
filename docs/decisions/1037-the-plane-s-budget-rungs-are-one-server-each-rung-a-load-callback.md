---
number: 1037
title: The plane's four budget rungs are served by one server, and each rung module says only where its ceiling and spend come from, what its summary names, and its own calls
date: 2026-11-17
status: accepted
issue: 1024
paths:
  - apps/troupe_plane/lib/troupe/plane/budget/rung.ex
  - apps/troupe_plane/lib/troupe/plane/person_budget.ex
  - apps/troupe_plane/lib/troupe/plane/profile_budget.ex
  - apps/troupe_plane/lib/troupe/plane/platform_budget.ex
  - apps/troupe_plane/lib/troupe/plane/team_budget.ex
symbols:
  - Troupe.Plane.Budget.Rung
gist: reserve, release and inspect live once in Budget.Rung; a rung module is load/summary/label (+ the team's record calls); registered under its own name
---

`Troupe.Plane.Budget.Rung` is the one GenServer behind the person's, the profile's, the
team's and the platform's rungs. It holds the deciding that was the same in all four:
reload on every reserve and inspect, a retry for one session is not a second slice,
spent plus held plus asked against the ceiling, reservations the ledger knows merged under
what the actor holds, release drops the slice, and the summary's spent, reserved, remaining
and node.

A rung module is a behaviour implementation with three callbacks: `load/1` (the ceiling as
`:unlimited` or a positive number, the spend this period, the ledger's open reservations,
and whatever its summary names), `summary/2` (its scope, key, budget and period, and for
the platform which cap bound) and `label/1`. `handle_call/3` is optional, for calls of the
rung's own: the team's `record` and `record_batch` stay in `TeamBudget`, so the ledger
cache is still invalidated by its only writer. Each rung keeps its public functions, and
its actor is still registered with `:global` under `{RungModule, key}` through
`Troupe.Plane.Singleton`, so callers and anything that looks a rung up by name are
unchanged. `Rung.ceiling/1` is the one place zero and `nil` become no ceiling.

Narrowed: Decision 470 (`PersonBudget` re-reads the ledger on every decision) is now
the shared server's rule for every rung, the team's and the platform's included; and in
Decision 44 the team budget actor is this server under the team rung's name. Decisions
49, 465 to 469, 258, 297, 300 and 910's rung are kept as they were.

Not chosen: one module with a scope argument and the four modules removed (every caller
and every `:global` lookup by module name would change, and the team's record calls would
sit beside reserving in a module about every scope); a macro that generates each rung's
whole GenServer (the duplicate would remain, only hidden).

What breaks if undone: four copies of the reserve and release logic, and a fix to how one
rung counts what it holds has to be made four times or the rungs disagree.
