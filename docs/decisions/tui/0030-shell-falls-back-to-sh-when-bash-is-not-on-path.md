---
number: 30
title: "`shell` falls back to `sh` when `bash` is not on PATH"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`shell` falls back to `sh` when `bash` is not on PATH"
---

A clean Alpine container (done item 32) has no bash; failing every shell command there would make the binary useless on musl-only hosts, and the tool description still reports the shell actually used.
