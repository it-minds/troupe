---
number: 962
title: "On Windows the daemon started at login runs detached from any console: the Startup entry runs `troupe-daemon run --detached`, which is `erl -detached`, the runtime's own way to run a daemon, so no window stays open and no script host is involved"
date: 2026-10-28
status: accepted
supersedes: [762]
paths:
  - apps/troupe_core/lib/troupe/start_at_login.ex
  - apps/troupe_core/test/troupe/start_at_login_test.exs
  - apps/troupe_daemon/lib/troupe/daemon/release.ex
  - apps/troupe_daemon/lib/troupe/daemon/cli.ex
  - apps/troupe_daemon/lib/troupe/daemon/application.ex
  - apps/troupe_daemon/rel/env.bat.eex
  - apps/troupe_daemon/rel/vm.args.eex
  - apps/troupe_daemon/test/troupe/daemon/release_test.exs
  - apps/troupe_daemon/README.md
  - clients/tui/lib/troupe/ui/setup.ex
  - clients/gui/apps/desktop/src/views/Onboarding/Daemon.tsx
  - docs/developer/gate-walk-rows.md
symbols:
  - Troupe.StartAtLogin.entry/2
  - Troupe.StartAtLogin.refresh/1
  - Troupe.Daemon.CLI.refresh_login/0
  - Troupe.Daemon.Release.wrapper/1
  - Troupe.Daemon.Release.detached_vm_args/1
gist: "The Windows login entry runs `troupe-daemon run --detached` (erl -detached via detached.vm.args, switched in env.bat), no console, no script host; eval never detaches"
---

A person who turned on starting at login on Windows got a console window on every login:
762 chose a console minimised to the taskbar, and the report was that the daemon "starts a
cmd console on start up and not as a true background service". This replaces 762's Windows
console part only; the rest of 762 stands (one module, each platform's own per-user entry,
only files, `TROUPE_DAEMON_IDLE_MINUTES=0`, the setup step).

- **What 762 was guarding against, and what it gave up.** 762 said a start with no window
  needs a script host (VBScript) or a hidden PowerShell, which is what malware looks like,
  and took the visible window as the price. That was true of the ways `cmd` and `start`
  offer; it is not true of the runtime. `erl -detached` is Erlang's own, documented way to
  run a daemon on every platform: on Windows the launcher closes its standard handles,
  spawns the emulator again as a detached process (no console, `ERL_CONSOLE_MODE=detached`)
  and returns at once. No script host, no shell kept alive, nothing a virus scanner reads
  as persistence beyond the Startup folder entry itself. The window a person could see and
  close goes, but the desktop app has started the daemon with no window since 903's
  `CREATE_NO_WINDOW`, so windowless is already the daemon's usual state on this platform;
  it is seen in Task Manager's Startup list (the folder entry) and as `erl.exe`, and
  stopped with `troupe-daemon stop`, by logging out, or from Task Manager.
- **How the flag reaches the VM.** The release script hands every command the same
  `vm.args`, and `eval` must never detach (a `status` run detached would answer nothing).
  So `troupe-daemon run --detached` is `bin/troupe_daemon start --detached`; the release's
  own `env.bat`, which the script calls with the command line before it settles
  `RELEASE_VM_ARGS`, points that at `releases/<vsn>/detached.vm.args`; and the `wrapper`
  release step writes that file as the rendered `vm.args` with `-detached` after it, so a
  flag added to `vm.args` reaches a detached daemon too. `run` takes `--detached` and no
  other option, and a `run` with a daemon already up still says where it is and exits 0.
  The Unix wrapper ignores the option: launchd and systemd give the daemon no terminal.
- **The entry keeps `start "troupe-daemon" /min cmd /c`.** Explorer gives a Startup item
  that is a batch file a console of its own, so some window exists until the wrapper has
  checked for a running daemon and the VM's launcher has returned, a second or two.
  `start` returns at once, so the entry's own window is gone in a blink, and the inner one
  is minimised for that moment and closes by itself. Dropping `start` would leave a
  full-size window for those seconds instead.
- **Where its output goes.** A detached VM has no standard output. The daemon's log has
  been `daemon.log` in the state directory, rotated, since it was made for clients that
  start it detached (`TROUPE_DAEMON_LOG`); the one line that went only to the console,
  "listening at", now goes to the log as well. `troupe-daemon status` finds it through
  `daemon.json` as before.
- **Not chosen.** A Windows service through the release's `install` (erlsrv): it needs an
  administrator to register, runs under a service account without the person's
  `%APPDATA%`, credentials or keyring, and the release refuses it with no distribution.
  A scheduled task at logon: a console program run in the person's session still shows
  its window, hiding it means running it outside the session, it is not "only files",
  and Task Manager's Startup list does not show it. `start /b`: shares the console that
  started it (802). `ELIXIR_ERL_OPTIONS=-detached` around the start: the VM hands its
  environment to every program it starts, so an agent's `mix test` would detach too.
  A `.lnk` with "run minimised": needs COM to write, and minimises rather than hides.
- **An entry from before refreshes itself.** A machine that had the entry before this
  change would keep its console after an update until somebody ran `login on` again, and
  nobody would. So the daemon, as it starts to serve (`Troupe.Daemon.Application`'s
  one-off task, after the "listening at" line), runs `Troupe.StartAtLogin.refresh/1`
  once: where an entry of this platform's kind is there, starts the `troupe-daemon` an
  entry would start now (the command as that kind's entry spells it is in the text) and
  is not what `entry/2` writes now, it is written again at the same path, and one line
  says so in the log. A current entry is not written (its time stays); a file at that
  path that starts something else is somebody else's and is left, as is any entry when
  no `troupe-daemon` can be found; the answer says which. Still only files, nothing
  started, every kind alike since any entry's shape can change. The daemon is the first
  thing that runs after an update on every platform, which is why it is there and not in
  an update step: `Troupe.Update`, `install.sh` and `install.ps1` have no hook after a
  new daemon is in place, and the installer leaves an entry it finds alone.
- **Proof:** `start_at_login_test.exs` (the Windows entry's exact text: `run --detached`,
  no bare `run` that would keep a console, a path beyond ASCII still read as UTF-8; an
  entry in the old shape rewritten in place, a current one left with its time, a foreign
  file and an entry with no `troupe-daemon` to name left with the reason),
  `release_test.exs` (the wrapper's `run --detached`, refused with anything else, `eval`
  never detached, every VM reading the null device; `detached.vm.args` derived from
  `vm.args`), the daemon's `cli_test.exs` and the TUI's setup screen tests. Not run on
  Windows in this change: a person should check that Task Manager's Startup list shows
  `troupe-daemon.cmd`, that no window appears after login, that `troupe-daemon status`
  finds the daemon, and that `%LOCALAPPDATA%\troupe\daemon.log` has its "listening at"
  line.
