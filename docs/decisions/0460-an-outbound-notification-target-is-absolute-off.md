---
number: 460
title: An outbound notification target is absolute, off the loopback and on the egress allowlist
date: 2026-09-16
status: accepted
paths:
  - apps/troupe_plane/test/troupe/plane/triggers_test.exs
gist: An outbound notification target is absolute, off the loopback and on the egress allowlist
---

LangGraph shipped a 2026 advisory because a *relative* target was
resolved against the server's own base URL and reached an in-process route with no
authentication. So a target with no scheme and no host is not a target; `127.0.0.1`
and `::1` and `localhost` and `::ffff:127.0.0.1` are the same attack written out;
and `169.254.169.254` is where cloud credentials live. Other private ranges are
*not* refused — a plane in a cluster has legitimate internal receivers — and what
governs those is the egress allowlist, which a platform admin sets and a team admin
cannot.
