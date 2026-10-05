---
number: 130
title: Everything a client does goes through `/rpc`, and everything `/rpc` does goes through `Troupe.Plane.Harness`
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
gist: Everything a client does goes through `/rpc`, and everything `/rpc` does goes through `Troupe.Plane.Harness`
---

That is the "any client, including our own, uses
nothing but public APIs" rule made structural rather than remembered: there is no
second path into the plane for the TUI to take.
