---
number: 56
title: "`Troupe.KMS` lives in `troupe_protocol`"
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_protocol/mix.exs
gist: "`Troupe.KMS` lives in `troupe_protocol`"
---

The plane may not depend on
`troupe_core`, and both the plane and the workers hold this contract — the plane
destroys keys and the workers create and read them. `troupe_protocol` is the only
place both can see, and it already holds the other contract the two sides share,
endpoint discovery.
