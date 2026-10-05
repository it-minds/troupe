---
number: 73
title: A session routes to `Client.Local` or `Client.Remote` by id, through the registry, and the route is owned by the worker connection
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/client.ex
gist: A session routes to `Client.Local` or `Client.Remote` by id, through the registry, and the route is owned by the worker connection
---

The TUI passes a session id around exactly as before, so local and remote sessions can be on screen in the same window and switching between them is `adopt/2` either way. A remote session's route exists only while it is attached; everything else is local, which makes "local by default" a property of the lookup rather than a flag anyone has to set.
