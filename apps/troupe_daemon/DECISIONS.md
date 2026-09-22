# Decisions — troupe-daemon

Numbered, one per deviation from the plan that named it
(`../../docs/history/brief-daemon.md`) or from what a reader would expect. The harness's own decisions are in
`troupe-remote/DECISIONS.md`; this file is about packaging it.

1. **A plain Mix release per platform, not a Burrito binary.** The brief said "one
   Burrito binary per platform", which is how the TUI ships and was the obvious shape. It
   does not fit a daemon. Burrito's launcher runs the VM as `erl -s elixir start_cli
   -extra <args>`: Elixir's command line takes the first argument as a file to run,
   prints `No file named run`, and halts the VM with status 1 — concurrently with the
   application's own start, which `application:start_boot` does not wait for. A daemon
   that has just bound its socket is killed a moment later; a `status` racing the same
   halt exits 1 whatever it found. The TUI survives this because it does its whole job
   synchronously inside application start and halts first, which a server cannot do. A
   release's `bin/troupe_daemon start` is the entry point a daemon wants: the VM stays up
   because the release script says `--no-halt`, applications start under supervision and
   nothing runs the command line over the arguments. `eval` and `remote` come with it,
   which is what the brief's item 7 — "`bin/troupe_daemon eval` works" — literally names.
   The cost is a tarball and a directory instead of one file, and an ERTS per platform,
   which the release workflow's native runners already provide. The user-facing command
   line is `bin/troupe-daemon`, a wrapper the release carries: `run` is `start`, the rest
   is `eval "Troupe.Daemon.CLI.eval([...])"` in a second short-lived VM that starts the
   harness applications and never the daemon.

2. **The reaper is built into the release for the host's triple, and the build fails
   without Zig.** `mix compile.reaper` runs while `troupe_core` compiles as a dependency,
   and skips with a warning when `zig` is missing. A daemon that shipped that way would
   fail every `shell` call with "reaper helper not built" — the failure seen on the live
   `dev` worker this week. `Troupe.Daemon.Release.reaper/1` builds the helper again, into
   the assembled release, and raises if it cannot. A release is built on the platform it
   runs on, so the host's triple is the only one it needs.

3. **The harness is pinned by commit, and the daemon has a version of its own.**
   `mix.exs` names one `troupe-remote` commit for all three apps and sets `TROUPE_VERSION`
   to the harness version that commit declares, because a sparse checkout has no
   `VERSION` file and the apps refuse to guess. `VERSION` here is the daemon's: a
   packaging change is a daemon release without a harness change, and a harness change
   is a bump of the pinned commit. `troupe-daemon version` prints both, and the protocol
   major, so a support question can be answered from one line.

4. **No Windows release yet, and the reason is upstream.** The release workflow's first
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

5. **Windows is back in the matrix, on a fork of `ezstd` that builds with Zig.** Entry 4
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

6. **The daemon is an application of the umbrella it used to pin, and entry 3 is over.**
   Entry 3 pinned the three harness apps to one `troupe-remote` commit and gave the daemon
   a version of its own. With `troupe-remote` now the monorepo (its DECISIONS.md 666 and
   667), the daemon is `apps/troupe_daemon`: its harness is the checkout it is built in, its
   version is the umbrella's `VERSION`, and the release is still defined in this directory.
   What entries 1, 2, 4 and 5 decided is unchanged — a plain release per platform, the
   reaper built for the host into the release, `ezstd` from the fork. Numbering here
   stops; later decisions about the daemon go in the root `DECISIONS.md`.
