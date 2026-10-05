---
number: 643
title: "`ezstd` comes from the it-minds fork, because upstream does not build on Windows"
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_protocol/mix.exs
gist: "`ezstd` comes from the it-minds fork, because upstream does not build on Windows"
---

`ezstd` 1.2.4 declares its rebar compile hook for `(linux|darwin)` only.
The fork (`it-minds/ezstd`, branch `win32-zig`, one commit meant for an upstream
pull request) adds a `win32` hook that compiles zstd — at the commit upstream
already pins — and the NIF with `zig cc`/`zig c++` into `priv/ezstd_nif.dll`; Zig
is the one toolchain the release runners and this repository already carry, so a
Windows build needs no Visual Studio and no MSYS2. Linux and macOS build exactly as
before, and the segment format is untouched. It is a git dependency pinned by
commit until upstream takes the change, which `docker/Dockerfile`'s builder stage
can fetch because it has `git`.
