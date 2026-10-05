---
number: 79
title: With the plane unreachable, `sessions.list` answers with the sessions this client is attached to instead of an error
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/client/remote.ex
gist: With the plane unreachable, `sessions.list` answers with the sessions this client is attached to instead of an error
---

They are on screen and streaming; listing nothing would be less true than listing them. Rows are built from what the worker connections know, and marked `attached`.
