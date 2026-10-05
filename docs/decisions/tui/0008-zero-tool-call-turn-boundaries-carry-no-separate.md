---
number: 8
title: Zero-tool-call turn boundaries carry no separate `llm_request_started` event
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Zero-tool-call turn boundaries carry no separate `llm_request_started` event
---

Whether an LLM call is outstanding is fully derivable from the last message role, so the log stays smaller and replay stays unambiguous; telemetry (not the log) carries LLM start/stop.
