---
number: 35
title: "`/quit` (also `/exit`, `/q`), Ctrl-D and Ctrl-Q exit the TUI in addition to Ctrl-C twice, and the status line always says so"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`/quit` (also `/exit`, `/q`), Ctrl-D and Ctrl-Q exit the TUI in addition to Ctrl-C twice, and the status line always says so"
---

Ctrl-C twice alone was undiscoverable and any other key disarmed it; a user got stuck. The TUI's supervisor entry is `:transient` so a deliberate quit is not restarted while a crash still is.
