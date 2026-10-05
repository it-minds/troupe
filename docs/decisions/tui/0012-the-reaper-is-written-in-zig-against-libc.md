---
number: 12
title: The `reaper` is written in Zig against libc/kernel32 declarations, cross-compiled by a Mix compiler (`mix compile.reaper`)
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The `reaper` is written in Zig against libc/kernel32 declarations, cross-compiled by a Mix compiler (`mix compile.reaper`)
---

Keeps zig the only native toolchain; the Mix compiler builds the host target for `mix test` and every target for releases.
