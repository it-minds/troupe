---
number: 29
title: A stream task crash is reported as `{:llm_error, ref, {:stream_task_down, reason}}`
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: A stream task crash is reported as `{:llm_error, ref, {:stream_task_down, reason}}`
---

The agent then rests `:done_unread` with the error visible instead of retrying forever or crashing.
