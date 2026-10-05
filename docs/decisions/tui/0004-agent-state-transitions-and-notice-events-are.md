---
number: 4
title: "`agent_state` transitions and `notice` events are transient too"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`agent_state` transitions and `notice` events are transient too"
---

They are derived from persisted events (or purely informational), so persisting them would duplicate the log; the TUI rebuilds from `branch_state` and the message events.
