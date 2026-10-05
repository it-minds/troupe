---
number: 9
title: The `finish`, `todo_write`, `todo_read`, `delegate` and `ask_user` tools are executed by `Agent.Server` itself rather than in a task
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
gist: The `finish`, `todo_write`, `todo_read`, `delegate` and `ask_user` tools are executed by `Agent.Server` itself rather than in a task
---

They only mutate or read agent state, or start supervised children / register a pending question, so a task would add a hop without isolation value; their execution is still logged with `tool_call_started`/`tool_call_completed`.
