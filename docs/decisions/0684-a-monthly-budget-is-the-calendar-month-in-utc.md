---
number: 684
title: A `monthly` budget is the calendar month in UTC, and it turns over because it is asked, not because a job runs
date: 2026-09-25
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/ledger.ex
gist: A `monthly` budget is the calendar month in UTC, and it turns over because it is asked, not because a job runs
---

It resets at 00:00 UTC on the 1st, the same instant
on every replica whatever zone anybody is in; decided for #106 over a zone set on the
plane and a rolling thirty days. Nothing is written at midnight. The period's start is
worked out on every read (`Ledger.period_start/1`) and the ledger's cache is keyed by
it, so the first read of a month is a new sum and not last month's remembered one.
`never` counts everything. A person's cap and the platform's (with the deployment's)
are that same month, always, decided for #132 over leaving them all-time: an all-time
cap refuses somebody for good once they reach it. They do not borrow a team's period,
because a person's cap follows them between teams (471) and somebody in a `monthly`
team and a `never` one would get two answers (`Ledger.month_start/0`).
