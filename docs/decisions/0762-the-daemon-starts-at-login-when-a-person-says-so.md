---
number: 762
title: "The daemon starts at login when a person says so: one module writes the platform's own per-user entry, removes it and says whether it is there, and a daemon started that way stays up until the person logs out"
date: 2026-10-04
status: accepted
issue: 76
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/setup.ex
  - apps/troupe_core/lib/troupe/start_at_login.ex
  - apps/troupe_core/test/test_helper.exs
  - apps/troupe_core/test/troupe/start_at_login_test.exs
  - apps/troupe_daemon/README.md
  - apps/troupe_daemon/lib/troupe/daemon/cli.ex
  - apps/troupe_daemon/test/troupe/daemon/cli_test.exs
  - apps/troupe_gateway/test/test_helper.exs
  - clients/gui/apps/desktop/src/views/Onboarding/Daemon.tsx
  - clients/gui/packages/client/src/setup.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/tui/lib/troupe/cli/config_setup.ex
  - clients/tui/test/troupe/config_setup_test.exs
gist: "The daemon starts at login when a person says so: one module writes the platform's own per-user entry, removes it and says whether it is there, and…"
---

Issue #76's last item, after 705.
`Troupe.StartAtLogin` is the one place; `troupe-daemon login on|off|status` (so also
`troupe daemon login …`) and the first run's new `daemon` step both call it. It is in
the harness, beside `Troupe.Setup`, because the step is the setup flow's and the
terminal client embeds the same code.
- **The entry is each platform's own, and none needs an administrator.** Windows: a
  `troupe-daemon.cmd` in the Startup folder, a file a person can see and delete, which
  Task Manager's startup list shows. macOS: a launchd agent run at load,
  `com.objective-mj.troupe.daemon`, named under the desktop app's identifier (710).
  Linux: a `systemd --user` unit wanted by `default.target`, written with the link
  `systemctl --user enable` would make, where `/run/systemd/system` says systemd runs
  the machine; elsewhere an XDG autostart entry, which only a desktop session reads,
  so a console login there starts nothing.
- **On Windows the daemon runs in a console minimised to the taskbar.** A start with no
  window needs a script host (VBScript, which Windows is retiring) or a hidden
  PowerShell, and both are how malware keeps itself running, which is what a virus
  scanner looks for. A minimised console can be seen, and closing it stops the
  daemon. The entry runs `cmd /c` so the window goes when the daemon does, and switches
  the console to UTF-8 only for a path beyond ASCII.
- **Only files.** Nothing is loaded into launchd or systemd and nothing is started:
  turning it on takes effect at the next login, and turning it off stops nothing that
  is running. The same on every platform, testable in a scratch home without the
  person's session manager, and a test cannot leave a service running.
- **It starts `troupe-daemon run` as a client finds it**: `TROUPE_DAEMON_COMMAND`, then
  the `PATH` (the installers' shim, whose path an upgrade or a rollback keeps), then the
  wrapper of the release it runs in. With none, turning it on is refused with the
  reason and writes nothing, and the desktop app's choice is greyed.
- **A daemon started at login does not exit when idle**: the entry sets
  `TROUPE_DAEMON_IDLE_MINUTES=0`. Starting at login is for having the daemon there;
  one that went away ten minutes after login would leave the entry doing nothing a
  client's start on demand does not. A daemon a client starts still exits when idle,
  and one stopped by hand is started on demand by the next client, idle rules and all.
- **The step is the answer, not a toggle.** `daemon` comes between `workspace` and
  `finish` on the local paths, `{"at_login": true | false}`: true writes the entry
  (again, picking up a moved binary), false removes one, so re-running Setup is also
  how it is turned off, and what is there now is the answer a screen presses.
  `setup.get` reports it as `daemon` (`at_login`, `kind`, `path`, `command`). A plane's
  path stays `where`, `finish` (705); `troupe daemon login on` is there for its users.
- **The terminal client asks it too**, after a first run saves settings and only where
  a `troupe-daemon` is installed, Enter meaning no, and answers yes with `troupe daemon
  login on`. Its full-screen flow is still a later slice.
- **Not the installer's.** #76 asked whether this belongs in the installer: the entry
  is the daemon's, so that one module knows the paths. An installer that offers it
  runs `troupe-daemon login on`, as it runs `config import-opencode`, and its
  uninstall should run `login off` first; neither does yet. A switch on the desktop
  app's settings screen is not in this change either: Setup asks again.
- **Proof:** `start_at_login_test.exs` (each platform's entry in a scratch home, its
  exact text and quoting, its removal, a unit nothing wants being off, the binary's
  discovery), `setup_test.exs` ("the daemon step …") and the daemon's `cli_test.exs`
  ("login turns …"), both failing on the chunk's tip; the gateway's setup test over
  the socket; the desktop app's onboarding test (the first run through the step, the
  screen on its own) against the client's fake daemon, and the first run in a browser
  against that fake, dark at desktop width and light at 380px; the terminal client's
  `config_setup_test.exs`; and on Windows, the installed `troupe-daemon login on`,
  `status` and `off`, and `troupe daemon login …` through the installed TUI, against a
  scratch `APPDATA`, the entry run as Explorer runs a Startup item starting a daemon
  that was still up after 100 seconds with `TROUPE_DAEMON_IDLE_MINUTES=1` around it,
  and the real Startup folder untouched, on the pull request. Every test writes
  into a scratch home: the suites set `:troupe_core, :start_at_login` to one.
