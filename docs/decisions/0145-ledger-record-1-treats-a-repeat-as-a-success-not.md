---
number: 145
title: "`Ledger.record/1` treats a repeat as a success, not an error"
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/ledger.ex
gist: "`Ledger.record/1` treats a repeat as a success, not an error"
---

A worker
replaying a queued report after a reconnect has done nothing wrong and must not be
told it has. `{:duplicate, existing}` hands back the record that stands — the
*first* one, because what the gateway billed is what the first report said — and
says which case it was, because a caller keeping a running total needs to know
whether to add this one.
