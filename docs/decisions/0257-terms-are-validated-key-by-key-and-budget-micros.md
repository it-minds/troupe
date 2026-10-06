---
number: 257
title: Terms are validated key by key, and `budget_micros` is trimmed rather than refused
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane
gist: Terms are validated key by key, and `budget_micros` is trimmed rather than refused
---

An unknown key is `invalid_params`, because the worker applies terms as
configuration and a misspelt cap is a cap that silently did not apply. A slice
larger than what the team has left becomes what is left: a nightly trigger near the
end of a budget period should run on the remainder and be stopped by the ledger,
not be refused for asking. Nothing left is `budget_exhausted` before a row exists.
There is no `approvals: "auto"`; a trigger that needs none gets a profile whose
definition says so, which is an admin's versioned act rather than a flag on a
schedule.
