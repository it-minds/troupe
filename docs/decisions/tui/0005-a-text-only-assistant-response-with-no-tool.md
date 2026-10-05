---
number: 5
title: A text-only assistant response with no tool calls is treated as an implicit `finish` with that text as the summary
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: A text-only assistant response with no tool calls is treated as an implicit `finish` with that text as the summary
---

Otherwise a branch whose model forgot to call `finish` would sit `:running` forever with nothing in flight; the built-in prompts still instruct the model to call `finish` explicitly.
