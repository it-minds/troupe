---
number: 130
title: Whether troupe has a terminal is asked of Burrito's launcher on Linux and macOS, and on Windows Ctrl-C ends the commands that only print
date: 2026-09-27
status: accepted
issue: 231
paths:
  - clients/tui/lib/troupe/cli/daemon.ex
  - clients/tui/lib/troupe/cli/interrupt.ex
  - clients/tui/lib/troupe/cli/terminal.ex
  - clients/tui/test/troupe/cli_daemon_test.exs
  - clients/tui/test/troupe/interrupt_test.exs
  - clients/tui/test/troupe/terminal_test.exs
gist: Whether troupe has a terminal is asked of Burrito's launcher on Linux and macOS, and on Windows Ctrl-C ends the commands that only print
---

Issue #231's follow-ups
(Decision 128 left them; root Decision 719 has the daemon's side).
- **The launcher's standard output is the one the person sees.** On Linux and macOS
  Burrito's launcher gives the VM a pipe for standard output and copies it to its
  own (`erlang_launcher.zig`, so that `troupe … | head` going away ends the VM too).
  So the VM's own standard output was never a terminal there, and the guard of 0.5.1
  (`Runner.needs_terminal/2`) refused plain `troupe` in a real terminal for everyone,
  as if it had been drawn into a file; `troupe config` asked nothing either. Shown
  with the v0.6.0-beta Linux asset and with a build of the chunk's tip, under a pty
  and under `script`: `troupe: stdout is not a terminal`, the VM's descriptor 1 a
  pipe and the launcher's `/dev/pts/4`. `Troupe.CLI.Terminal` asks the launcher, the
  VM's parent: `/proc/<pid>/fd/1` on Linux, `lsof` elsewhere, and a standard output
  it cannot read counts as a terminal, since refusing on a guess is what went wrong.
  A file, a pipe or no terminal at all is still refused. Standard input the launcher
  passes on as it is, and on Windows it hands the VM its console: there the VM's own
  answers stand.
- **Ctrl-C at a command that only prints, on Windows.** Under `+Bc` Ctrl-C is a key,
  and `troupe run --headless`, `troupe daemon run`, `troupe login` and the others
  that wait on a daemon or a network read none, so the key waited for the shell,
  which read it into its next line. `Troupe.CLI.Interrupt` reads the console while
  they run (`Runner.interruptible?/1` lists them), through the same reader the
  terminal UI uses (`ExRatatui.poll_event/1`): every key typed is taken off, and
  Ctrl-C prints `^C` and ends the command with 130. The terminal UI and a question
  read Ctrl-C themselves and are not watched.
- **`troupe daemon` runs the daemon under the reaper on Windows**, in a job that ends
  with troupe however troupe ends. Started through a batch file, the daemon got no
  signal of its own, and without the job it went on in the console after troupe had
  gone. Elsewhere Ctrl-C is the terminal's signal, reaches the daemon too, and
  nothing changes.
- **What is left: Ctrl-Break opens the VM's break menu.** It is a signal whatever
  the console's mode, and ERTS gives no flag that makes it end the VM
  (`sys_interrupt.c`, `erl_init.c`): under `+Bc` it is still the break handler's,
  `+Bi` ignores it and leaves the VM behind the launcher that died of it, and `+Bd`
  is not read on Windows at all. A second Ctrl-Break ends the VM. Ending it on the
  first takes a console control handler inside the VM, a NIF of our own.
- **Unix Ctrl-C, checked.** At `troupe login` under a pty the launcher dies of SIGINT
  and the VM with it, and nothing of troupe is left three seconds later; nothing
  changes there.
- **Proof:** `test/troupe/terminal_test.exs` (the launcher is asked only behind the
  pipe; a file, a pipe and `/dev/null` are refused and a terminal is not; another
  process's standard output read from `/proc`, and with `lsof` and `ps` as on
  macOS), `test/troupe/interrupt_test.exs`, `test/troupe/cli_daemon_test.exs` ("the
  daemon goes when the process that ran it goes", which the old spawn fails), the
  Linux binary under a pty, and the Windows binary in console windows, before and
  after, on the pull request.
