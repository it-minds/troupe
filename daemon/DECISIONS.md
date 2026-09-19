# Decisions — troupe-daemon

Numbered, one per deviation from the plan that named it (`../docs/brief-daemon.md`) or
from what a reader would expect. The harness's own decisions are in
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
