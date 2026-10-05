---
number: 7
title: Cancellation puts the agent in `:done` with reason `:cancelled` (window `:done_unread`)
date: 2026-09-11
status: accepted
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/test/troupe/window_attention_test.exs
gist: Cancellation puts the agent in `:done` with reason `:cancelled` (window `:done_unread`)
---

Leaving it `:running` after killing its work would show a live window doing nothing; `:done` lets the user read what happened and continue with a follow-up.
