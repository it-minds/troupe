---
number: 802
title: "On Windows a daemon a client starts gets a console of its own, minimised, as the login entry's does, so closing the terminal it was started from leaves it running; and `troupe-daemon open` takes the web app's address from the plane's discovery document, `plane.app`"
date: 2026-10-06
status: accepted
paths:
  - apps/troupe_protocol/lib/troupe/protocol/daemon.ex
  - apps/troupe_daemon/lib/troupe/daemon/cli.ex
  - apps/troupe_daemon/README.md
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_gateway/test/troupe/gateway/autospawn_test.exs
  - apps/troupe_daemon/test/troupe/daemon/cli_test.exs
  - apps/troupe_plane/test/troupe/plane/web_test.exs
symbols:
  - Troupe.Protocol.Daemon.detach_line/2
  - Troupe.Daemon.CLI.open/2
gist: A client-started daemon on Windows gets its own minimised console (start /min, never /b); open follows the plane's plane.app, else <plane>/app/
---

D79's first two items, which the #449 fixer left (797).

- **What was wrong, measured.** `Troupe.Protocol.Daemon` started a daemon on Windows with
  `start "" /b`, in the console of whatever started it. On this machine, with the
  installed 0.8.6 build and scratch homes, `troupe-daemon open` in a console window
  started a daemon there; Ctrl-C in that window left it running, since `start /b` starts
  a program that ignores Ctrl-C, so D79 overstated that half; but closing the window ended
  it, because a console tells every process attached to it that it is closing. A daemon
  that goes when a terminal is closed is not a daemon, and `open` is typed in a terminal
  a person will close.
- **A console of its own, minimised, as the login entry's (762).** The line is now
  `start "troupe-daemon" /min cmd /c "<program>"`: the same choice for the same reasons,
  a window a person can see and close rather than a hidden process, under `cmd /c` so the
  window goes when the daemon does (`start` runs a batch file under `cmd /k`, which keeps
  it). The title still comes before the program, which 691 is about. A daemon a client
  starts still exits when idle; only the login entry's does not. Its output now goes to
  its own window rather than the null device, so a person who opens it sees where it
  listens, and what `start` itself prints comes back to the client that ran it.
- **Not chosen.** A start with no window at all: `start` cannot ask for one and Erlang's
  `open_port` has no option for it, and the ways that can are a hidden PowerShell or a
  script host, which 762 turned down as what malware looks like. Keeping `/b` and
  ignoring the close event: the close event is not one a process can ignore for long;
  Windows ends it after the handler returns.
- **The app's address.** The plane's discovery document gains `plane.app`, named as its
  other addresses are (`rpc`, `jwks`): `TROUPE_APP_URL`, which the chart sets to
  `plane.appUrl` or to the GUI it mounts, resolved against the plane's own URL
  (`TROUPE_BASE_URL`, else the request's), as a browser resolves the index's door, so it
  is an address a program can open as it is. Null where no app is mounted. Additive: no
  client reads it but `open`, and the others ignore a field they do not know.
- **`open` follows it.** With no `--url`, `open` asks the linked plane's
  `/.well-known/troupe` (five seconds, no retries) and opens `plane.app` when it is an
  http or https address, resolved against the plane's address so a path works too.
  Anything else, no field, null or no answer, is the plane's `/app/`, as before, since
  `open` works offline (797). `--url` asks nothing. This replaces 797's "the plane is not
  asked where its app is"; the rest of 797 stands. The address the plane names is handed
  the token and admitted, as `--url`'s is, which gives the plane nothing it did not have:
  its own origin is admitted already and it serves the page `open` opened before.
- **Asked once the daemon is up.** Whether `open` is linked is settled before anything
  starts, as before, but the plane is asked after the daemon is started. Asked first, on
  Windows, the daemon that `open` then started kept the output of whatever ran `open`:
  PowerShell's `$out = troupe-daemon open 2>&1` waited until the daemon was stopped (93
  and 393 seconds), where the same with `--url`, or with the release before this one,
  came back in 3. A program a VM starts on Windows inherits that VM's handles (plain
  `elixir` showed it with both `start` lines), and the request was what put the caller's
  in reach of the daemon here; why, exactly, was not run down.
- **Not in this.** A plane whose `plane.app` is null still gets its `/app/` opened, and a
  404, as before: the done-when asks for the fall-back, and telling a person their plane
  has no app is a message of its own. Nor the handles a daemon inherits on Windows from
  the client that starts it, for any client but `open`: a follow-up of its own.
- **Proof:** on the chunk's tip, failing: the gateway's `AutospawnTest` (the Windows line,
  `start "" /b`), the daemon's `CLITest` "linked, it opens the web app the plane's
  discovery document names", against a plane stand-in over HTTP in the test, and "a path
  the plane names is on the plane ...", and the plane's `WebTest` "says where the web app
  is" (no field). All four pass with the change, beside `CLITest`'s plane that does not
  answer, the plane asked only after the daemon started, and `--url` asking nothing. On
  Windows, with scratch homes, in a console window minimised so that it is a console
  window and not a Windows Terminal tab, closed with the message its X sends: the
  installed 0.8.6 build's `open --url` started a daemon that lived through Ctrl-C there
  and ended with the window; the new `start` line run by hand, and then the installed
  build of this change, started one that answered `status` after both, in a minimised
  window of its own titled `troupe-daemon`. The installed build linked to a plane
  stand-in on `127.0.0.1` whose `plane.app` named another port opened that address and
  admitted its origin; linked to a port nothing answers, it opened the plane's `/app/`;
  both returned at once to a PowerShell capturing their output. And from a tab of the
  terminal panel this was developed in, `open --url` and the tab closed, after which
  `status` still answered; that panel ends only the shell when a tab closes, so the
  0.8.6 daemon lived through it as well, and the console window is the test that tells
  the two apart.
