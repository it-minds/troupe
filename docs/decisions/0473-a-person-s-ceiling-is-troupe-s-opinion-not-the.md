---
number: 473
title: A person's ceiling is Troupe's opinion, not the provider's
date: 2026-09-16
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/*budget.ex
gist: A person's ceiling is Troupe's opinion, not the provider's
---

It lives on the
`users` row but is written through a changeset of its own, never the one SCIM and a
login use. A cap that could arrive through the provider's door is a cap the next
nightly sync silently resets.
