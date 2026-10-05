---
number: 33
title: The Dispatcher releases a finished branch's Node only if that `done_unread` event is still the branch's latest `branch_state` in the log
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The Dispatcher releases a finished branch's Node only if that `done_unread` event is still the branch's latest `branch_state` in the log
---

A user can continue a branch before the Dispatcher has folded the `done_unread` event; without the check the stale event would kill a branch that is running again (found by the 10-run loop).
