---
number: 1
title: A plain Mix release per platform, not a Burrito binary
date: 2026-09-19
status: accepted
paths:
  - apps/troupe_daemon/mix.exs
gist: A plain Mix release per platform, not a Burrito binary
---

The brief said "one
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
