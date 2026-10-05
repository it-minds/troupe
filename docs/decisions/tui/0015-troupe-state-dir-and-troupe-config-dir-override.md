---
number: 15
title: "`TROUPE_STATE_DIR` and `TROUPE_CONFIG_DIR` override the platform dirs"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`TROUPE_STATE_DIR` and `TROUPE_CONFIG_DIR` override the platform dirs"
---

Tests need isolated state and config directories; the platform defaults from the spec are unchanged when the variables are unset.
