---
number: 719
title: "On Windows the daemon's VM reads nothing of the console and has no break menu for Ctrl-C: `-noinput` and `+Bc`, and the null device for standard input"
date: 2026-09-27
status: accepted
issue: 231
paths:
  - apps/troupe_daemon/lib/troupe/daemon/release.ex
  - apps/troupe_daemon/rel/vm.args.eex
gist: "On Windows the daemon's VM reads nothing of the console and has no break menu for Ctrl-C: `-noinput` and `+Bc`, and the null device for standard input"
---

Issue #231's
follow-up for the daemon (TUI Decision 130 has the TUI's side). The daemon release
had the stock `vm.args`, so a daemon in a console, `troupe-daemon run` typed there
or the one `troupe daemon run` starts, had a reader on it and the break handler's
menu for Ctrl-C and Ctrl-Break, which then read the console beside the shell.
`apps/troupe_daemon/rel/vm.args.eex` now gives the Windows build `-noinput` and
`+Bc`, and `bin/troupe-daemon.cmd` starts every VM with the null device as standard
input. The two go together: `+Bc` turns off the console's processed input through
the VM's standard input, so given the console it would make Ctrl-C a key nobody
reads here, and the daemon could not be stopped with it. Given the null device it
leaves the console alone, Ctrl-C stays a signal, and under `+Bc` that signal is
passed to Windows' own handler, which ends the VM at once with no menu to answer.
`+Bi` would ignore Ctrl-C and leave the daemon running, and `+Bd` is not read on
Windows. Ctrl-Break still opens the menu, which then reads the null device, finds
nothing and ends the VM. The Unix build is unchanged: there Ctrl-C is SIGINT to the
terminal's process group. Proof: the Windows release, `troupe-daemon run` in a
console window and under `troupe daemon run`, with Ctrl-C, before and after, on the
pull request.
