---
number: 383
title: "`kms.assertion` refuses a deactivated owner, and that is the door that mattered"
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/connections.ex
gist: "`kms.assertion` refuses a deactivated owner, and that is the door that mattered"
---

A running session needs nobody to sign in. Refusing a deprovisioned
person only at the harness would have left their credentials reachable by any pod
for as long as anything they had started kept running — indefinitely, since the pod
refreshes on its own. Refused here, the window is the pod's existing key-manager
token and its lease, and no longer.
