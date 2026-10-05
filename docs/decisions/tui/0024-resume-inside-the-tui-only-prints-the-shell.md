---
number: 24
title: "`/resume` inside the TUI only prints the shell command"
date: 2026-09-11
status: superseded
paths:
  - clients/tui
gist: "`/resume` inside the TUI only prints the shell command"
---

Swapping the live session under a running TUI adds a second session lifecycle to the UI for little value; `troupe resume [ID]` from the shell does it.
