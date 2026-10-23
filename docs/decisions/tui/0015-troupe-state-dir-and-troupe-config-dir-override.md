---
number: 15
title: "`TROUPE_STATE_HOME` and `TROUPE_CONFIG_HOME` override the platform dirs"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`TROUPE_STATE_HOME` and `TROUPE_CONFIG_HOME` override the platform dirs"
---

Tests need isolated state and config directories; the platform defaults from the spec are unchanged when the variables are unset.

The variables were first written here as `TROUPE_STATE_DIR` and `TROUPE_CONFIG_DIR`; the code
reads `TROUPE_STATE_HOME` and `TROUPE_CONFIG_HOME` (`Troupe.Paths`), and this text now names
them as it does. The number and the file's name are unchanged.
