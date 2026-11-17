---
number: 802
title: "On Windows a daemon a client starts gets a console of its own, minimised, as the login entry's does, so closing the terminal it was started from leaves it running; and `troupe-daemon open` takes the web app's address from the plane's discovery document, `plane.app`"
date: 2026-10-06
status: accepted
paths:
  - apps/troupe_protocol/lib/troupe/protocol/daemon.ex
  - apps/troupe_daemon/lib/troupe/daemon/cli.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
symbols:
  - Troupe.Protocol.Daemon.detach_line/2
  - Troupe.Daemon.CLI.open/2
gist: A client-started daemon on Windows gets its own minimised console (start /min, never /b); open follows the plane's plane.app, else <plane>/app/
---

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
