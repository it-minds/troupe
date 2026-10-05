---
number: 5
title: Windows is back in the matrix, on a fork of `ezstd` that builds with Zig
date: 2026-09-19
status: accepted
supersedes: [4]
paths:
  - apps/troupe_daemon/README.md
gist: Windows is back in the matrix, on a fork of `ezstd` that builds with Zig
---

Entry 4
named two ways out and this is the first: `it-minds/ezstd` (branch `win32-zig`, one
commit on upstream `master`) adds a Windows rebar hook that fetches zstd at the commit
upstream pins and compiles it and the NIF with `zig cc`/`zig c++` for
`x86_64-windows-gnu` into `priv/ezstd_nif.dll`. Zig is already on every release
runner for the reaper, so the Windows job gained no toolchain; Linux and macOS build
`ezstd` exactly as before, through its `Makefile`. `troupe_protocol` takes the fork as
a git dependency pinned by commit (`troupe-remote` DECISIONS.md 643), the daemon's
harness pin moves to that commit, and the on-disk segment format is unchanged — same
zstd, same frames. The one thing that was not obvious: rebar3 matches hook regexes
against OTP's own architecture string, which on OTP 25+ is `x86_64-pc-windows`, not
the `win32` the older hooks in the wild look for; the hook matches both. The Windows
smoke step unpacks the tarball, runs `version` and `status` through
`troupe-daemon.cmd`, and round-trips a binary through `:ezstd` in `eval`, which is
where a NIF that did not build would fail. It still does not start the daemon: a
background process in `pwsh` on a runner is its own piece of work, and the transport
is covered by `tcp_transport_test.exs` in the harness. The fork's commit is written as
an upstream pull request; when that lands, the dependency goes back to Hex.
