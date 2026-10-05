---
number: 262
title: A service principal's secret is a salted SHA-256, not argon2id
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/principals.ex
  - apps/troupe_plane/lib/troupe/plane/identity/service_principal.ex
gist: A service principal's secret is a salted SHA-256, not argon2id
---

The repository
has no key-derivation dependency and takes none on for this. The secret is 32
random bytes — 256 bits of entropy — so a fast hash is not the weakness it would be
for a password somebody chose; the salt is per principal so two hashes never
compare, and the comparison is `:crypto.hash_equals/2`. A wrong secret, a missing
subject and a disabled principal are one refusal. A trigger's key, a share, a
host's secret and the SCIM connector's token are held the same way.
