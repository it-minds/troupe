---
number: 461
title: The target is checked at save and again at send, and the second check resolves the name
date: 2026-09-16
status: accepted
paths:
  - apps/troupe_plane
gist: The target is checked at save and again at send, and the second check resolves the name
---

A check only at save is a check against the value, not against what the
value does: a host that passed on Tuesday and answers `127.0.0.1` today is a DNS
rebind, and only a check that asks DNS at send sees it. Redirects are not followed,
for the same reason — a target answering `302 http://127.0.0.1/` would carry the
request somewhere neither check ever looked at, which would make both of them
decoration.
