---
number: 1073
title: "The plane keeps whether a call was priced: a pod's usage record says `priced` beside the cost, the ledger keeps it per row, and the profile's page, the overview and the desktop's rail say how many calls of the period had no price; budgets still count them as free"
date: 2026-11-19
status: accepted
issue: 1137
paths:
  - apps/troupe_core/lib/troupe/session/usage.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/ledger.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - clients/gui/packages/client/src/profile.ts
  - clients/gui/apps/console/src/views/Overview.tsx
  - clients/gui/apps/desktop/src/views/Profiles.tsx
symbols:
  - Troupe.Plane.Ledger.unpriced/1
gist: "Usage record carries priced (a cost_micros of 0 or more on the call); usage_records.priced, default true; Ledger.unpriced/1 per team, person, profile for the period; profile.get limits.unpriced, admin overview unpriced_calls, admin profile budget.unpriced; budgets unchanged"
---

Issue #1137. Narrows Decision 689's "a pod's usage batch carries the cost and not where it
came from": it now carries whether anybody priced the call. Where the cost came from is
still not said, and 689's rule that a call nobody prices counts as free stands.

- **The record.** `Troupe.Session.Usage` sets `priced` where the call's `gateway.cost_micros`
  is a whole number of 0 or more (the gateway's, the catalog's or `models.prices`'s), and
  sends it in `usage.batch` beside `cost_micros`, which is 0 for an unpriced call as before.
  A record without the flag, from a pod before it, is priced where `cost_micros` is a number
  and unpriced where it is absent or null.
- **The ledger.** `usage_records.priced`, not null, default true: a row from before the
  column was charged as priced and reads so. `Ledger.unpriced/1` counts the unpriced calls
  and their tokens for a team over its period, and for a person and a profile over the
  calendar month in UTC, the periods their spend is read over; `nil` for none.
- **Where it is said.** `profile.get`'s `limits.unpriced` `{calls, tokens, since}`;
  `admin.profile.get`'s `budget.unpriced` the same; `admin.overview`'s teams and a team's
  members `unpriced_calls`. The console says it on the profile's page and as a line under
  Needs attention per team, with the two ways to price them; the desktop's rail one sentence
  under At a glance.

Not chosen: charging an unpriced call a guessed price (689: nothing rather than a guess);
refusing a session whose model has no price (a working session stopped over bookkeeping);
saying where the cost came from per row (the reconciliation needs only priced or not).

Undone, a team whose model has no price reads as having spent nothing, and nothing on the
plane says so but the pod's log.
