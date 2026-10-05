---
number: 78
title: HQ renders when the plane is down
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/ui/hq.ex
gist: HQ renders when the plane is down
---

The banner says creating and activating are unavailable, the sessions already known stay listed, and attached sessions keep streaming — the degraded mode the contract asks for is a supervision property (`one_for_one` over the plane and the sessions) plus one banner, not a mode anything switches into.
