---
number: 382
title: The harness checks on every call, not only at sign-in
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_worker/lib/troupe/worker/auth.ex
gist: The harness checks on every call, not only at sign-in
---

A plane token outlives
the moment it was issued, so a person deactivated at ten o'clock holds a valid one
until it expires. Checking at the door would leave every method answering them
until then. It reads the *row*: the provider's decision reaches us through SCIM,
and nothing re-reads a claim.
