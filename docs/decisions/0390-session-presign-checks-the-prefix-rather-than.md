---
number: 390
title: "`session.presign` checks the prefix rather than trusting it"
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
gist: "`session.presign` checks the prefix rather than trusting it"
---

The plane holds an
object-storage credential — 90 said it would not — and the narrowness is the whole
argument: it signs one method on one key under `sessions/<id>/` of a session the
caller owns, for five minutes, and has no key for the ciphertext. A signer that
signs whatever it is handed would be an object-storage credential with extra steps,
which is the thing 90 was about.
