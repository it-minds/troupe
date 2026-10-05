---
number: 125
title: A bundle version is immutable and a session is pinned at creation
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core
gist: A bundle version is immutable and a session is pinned at creation
---

A session
whose agent definitions changed underneath it would be a different session halfway
through. The only way a session's configuration ever moves is a deliberate upgrade
at activation, when the version it was pinned to has been retired — and that lands
in the log as `config_upgraded`, because the model is entitled to know its tools
may have changed.
