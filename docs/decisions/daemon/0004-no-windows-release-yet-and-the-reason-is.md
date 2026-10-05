---
number: 4
title: No Windows release yet, and the reason is upstream
date: 2026-09-19
status: superseded
paths:
  - apps/troupe_gateway/test/troupe/gateway/tcp_transport_test.exs
  - install.ps1
gist: No Windows release yet, and the reason is upstream
---

The release workflow's first
full run built and smoked Linux x86_64, Linux aarch64, macOS x86_64 and macOS aarch64
and failed on Windows at `mix deps.compile`: `ezstd`, the zstd NIF `troupe_protocol`
compresses sealed log segments with, declares its build hooks for `(linux|darwin)`
only and has no Windows build at all (`===> Missing artifact priv/ezstd_nif.so`). That
is not a toolchain the runner lacks; it is a dependency that does not build there. The
Windows target is out of the matrix until it does — either `ezstd` gains a `win32`
hook (Zig is on the runner and cross-compiles C; a fork or a patch is a day's work) or
the harness takes a zstd dependency that ships Windows binaries. The daemon's
Windows-specific code path, loopback TCP with a token in `daemon.json`, is tested in
`troupe-remote` (`tcp_transport_test.exs`) and is not what is missing; a Windows user
runs the Linux release under WSL in the meantime, which is how this repository is
developed. `bin/troupe-daemon.cmd` and `install.ps1` stay in the tree, unexercised.
