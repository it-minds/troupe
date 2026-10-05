---
number: 299
title: A charge dated in the future is dated now
date: 2026-09-13
status: accepted
paths:
  - apps/troupe_worker
gist: A charge dated in the future is dated now
---

A pod with a fast clock would
otherwise write charges into a window no report asks about, and a charge nobody can
see is worse than one dated a few seconds early. The event's own timestamp is used
otherwise, so a record folded out of a log an hour later still lands in the window
the call happened in.
