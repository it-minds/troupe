---
number: 92
title: The object store and the session layout live in `troupe_protocol`, not in `troupe_worker`
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane
gist: The object store and the session layout live in `troupe_protocol`, not in `troupe_worker`
---

They are a contract both sides hold, for the same reason the KMS
behaviour is: an index rebuild reconstructs the plane's index from storage, and the
plane cannot depend on the worker. What the plane can read there is bounded not by
where the code lives but by what it has a key for — and it has none.
