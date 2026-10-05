---
number: 13
title: OS processes needed by the harness itself (git, ripgrep, inotifywait probing) also run through reaper
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: OS processes needed by the harness itself (git, ripgrep, inotifywait probing) also run through reaper
---

The spec forbids any OS process outside reaper; the cost is one extra exec per call.
