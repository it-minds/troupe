---
number: 2
title: The reaper is built into the release for the host's triple, and the build fails without Zig
date: 2026-09-19
status: accepted
paths:
  - apps/troupe_daemon/lib/troupe/daemon/release.ex
gist: The reaper is built into the release for the host's triple, and the build fails without Zig
---

`mix compile.reaper` runs while `troupe_core` compiles as a dependency,
and skips with a warning when `zig` is missing. A daemon that shipped that way would
fail every `shell` call with "reaper helper not built" — the failure seen on the live
`dev` worker this week. `Troupe.Daemon.Release.reaper/1` builds the helper again, into
the assembled release, and raises if it cannot. A release is built on the platform it
runs on, so the host's triple is the only one it needs.
