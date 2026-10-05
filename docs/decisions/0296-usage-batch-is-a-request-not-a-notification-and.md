---
number: 296
title: "`usage.batch` is a request, not a notification, and its answer is the watermark"
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_worker
gist: "`usage.batch` is a request, not a notification, and its answer is the watermark"
---

A notification would leave the pod guessing what landed. `usage_seq` on the session
row moves as `greatest(current, offered)` so a retried older batch cannot walk it
backwards, and is **not** fenced on the epoch: a pod that has since been fenced
still made the calls it is reporting, and refusing them loses money rather than
protecting anything.
