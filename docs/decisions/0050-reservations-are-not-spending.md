---
number: 50
title: Reservations are not spending
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/ledger.ex
  - apps/troupe_plane/lib/troupe/plane/ledger/
gist: Reservations are not spending
---

What a session promised and what its model calls
cost are separate tables. The ledger is unique on the gateway's request id, so a
worker replaying its reports after an outage is not a second charge — and that
uniqueness is what makes the nightly reconciliation against the gateway meaningful.
