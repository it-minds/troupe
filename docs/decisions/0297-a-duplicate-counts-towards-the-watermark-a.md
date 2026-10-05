---
number: 297
title: A duplicate counts towards the watermark; a failed insert stops it
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_plane
gist: A duplicate counts towards the watermark; a failed insert stops it
---

A watermark
that refused to move past a record already in the ledger would ask the pod to send
it forever. A watermark that moved past a record that failed to insert would lose
it. Records are therefore applied in sequence order and the batch halts at the first
real error.
