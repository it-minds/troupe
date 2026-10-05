---
number: 128
title: A start that fails says why in one line and gives the terminal back, and on Windows the VM neither reads the console nor outlives the launcher's Ctrl-C
date: 2026-09-27
status: accepted
issue: 231
paths:
  - clients/tui/lib/troupe/cli/prompt.ex
  - clients/tui/rel/vm.args.eex
gist: A start that fails says why in one line and gives the terminal back, and on Windows the VM neither reads the console nor outlives the launcher's…
---

Issue #231; root Decision 718 has the cause. In a Burrito binary the runner is the
application's start, so an exit that escaped it (the daemon link's call timing out)
failed the VM's boot. The person saw `{exit,terminating,[{application_controller,…`
and never the reason, the VM hung stopping the rest, and a Ctrl-C then killed
Burrito's launcher alone and left the VM's break menu reading the console beside the
shell, which is where the stray keystrokes went.
- **One line, then halt.** `Runner.guard/1` catches exits, exceptions and throws
  around the command line and prints `troupe: could not start: <reason>`, status 1;
  an exit is told by its reason and the innermost call it stopped. The daemon link
  says in words what went wrong with the daemon, a call past its timeout (`the
  daemon did not answer session.create within 30 s`) or a daemon that took the
  connection and never answered (`no connection to the daemon at tcp:…`), and a
  call past its timeout no longer kills the link with its caller.
- **The terminal back on every way out.** The runner stops the windows, and waits,
  before it prints or halts: the terminal UI's own stop leaves raw mode and the
  alternate screen and shows the cursor. It used to halt 50 ms after telling the UI
  to quit. On Windows, a terminal UI that never came also drops the keys typed while
  it started, which the shell would otherwise read as a command line.
- **`rel/vm.args.eex`, Windows only: `-noinput` and `+Bc`, not the `+Bi` the issue
  proposed.** The launcher dies of any Ctrl-C the console signals, whatever the VM
  does. Under `+Bi` the VM ignored it and stayed on in the console, still starting
  the terminal UI or waiting on a question, beside the shell: reproduced here. Under
  `+Bc` the console makes a key of Ctrl-C while troupe runs, so nothing dies and no
  menu opens; the terminal UI reads it, and a Ctrl-C another program signals ends
  the VM with the launcher. The shell has the signal back at its prompt.
- **Questions read key by key on Windows.** A cooked read there never ends while
  troupe runs, since the console only makes a line end of Enter when it also makes a
  signal of Ctrl-C. `Troupe.CLI.Prompt` turns the VM's reader on raw and does the
  console's line editing (echo, or none for a key; Backspace; arrow keys dropped;
  Enter), and a Ctrl-C at a question ends the command with status 130.
- **What is left, on Windows.** Ctrl-C does not interrupt a command that stays in
  the console's cooked mode, `troupe run --headless` or `troupe daemon run` (close
  the window, or `troupe daemon stop`), and the key it leaves is the shell's to read
  at its next line, where cmd takes it as part of the command. Ctrl-Break still
  reaches the break handler. After a first run that asked questions, the VM's reader
  stays on beside that session's terminal UI, as it was on every run before.
- **Unix unchanged.** Its launcher dies of SIGINT the same way, and `+Bd`, no break
  handler so the VM dies with it, would be the equivalent; nothing here can show it.
- **Proof:** `test/troupe/runner_guard_test.exs` (an exit, an exception and a throw
  are one line and status 1, and the windows close before it is printed),
  `test/troupe/prompt_test.exs`, and the built binary in real console windows on
  the machine of the issue, before and after, on the pull request.
