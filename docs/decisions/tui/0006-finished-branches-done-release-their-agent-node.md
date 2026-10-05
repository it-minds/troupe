---
number: 6
title: Finished branches (`:done`) release their `Agent.Node`
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/node.ex
gist: Finished branches (`:done`) release their `Agent.Node`
---

Done item 15 requires no `Agent.Node` alive with `:done_unread` windows, so the Dispatcher terminates the Node on `branch_state: done_unread`; "continue" re-spawns a Node for the same `agent_path` and it rebuilds the conversation from the log, which is the same fold a crash restart uses.
