---
number: 36
title: Each window shows a live activity line (`⠋ thinking (00:07)`, `running shell … (00:03)`, `waiting for you`, plus nested subagent states) driven by the transient `agent_state` events, and providers forward reasoning/thinking deltas as live text that is never persisted
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Each window shows a live activity line (`⠋ thinking (00:07)`, `running shell … (00:03)`, `waiting for you`, plus nested subagent states) driven by…
---

Tool-calling models emit no text until the call is complete, so a window otherwise shows nothing but a timer while it works.
