---
number: 797
title: "`troupe-daemon open` starts the daemon and opens the web app with the loopback WebSocket's port and token after a `#`; the page takes them off its address bar and keeps them in `localStorage`, and the loopback admits the linked plane's origin and the page's"
date: 2026-10-06
status: accepted
issue: 449
paths:
  - apps/troupe_daemon/lib/troupe/daemon/cli.ex
  - apps/troupe_gateway/lib/troupe/gateway/loopback.ex
  - apps/troupe_gateway/lib/troupe/gateway/web.ex
  - apps/troupe_protocol/lib/troupe/protocol/endpoint.ex
  - clients/gui/apps/desktop/src/shell.ts
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/views/Local.tsx
symbols:
  - Troupe.Daemon.CLI.open/2
  - Troupe.Daemon.CLI.browser_target/2
  - Troupe.Gateway.Loopback.admitted/0
  - Troupe.Protocol.Endpoint.admit_ws_origin/1
gist: Loopback admits the linked plane's and open's origins; GUI keeps the daemon endpoint in localStorage; open never prints the token or puts it in argv
---

Issue #449. Connecting the web app to the daemon on the same machine took four steps by
hand: start the daemon with `TROUPE_ALLOWED_ORIGINS` naming the app's origin, read
`ws.port` and `ws.token` out of `daemon.json` (not the top-level pair, which is the native
transport's), type them into *This computer*, and do the last two again after every
daemon restart and every closed tab. A step done wrong said only that the socket could
not open.

- **One command.** `troupe-daemon open [--url URL]` starts the daemon if none answers,
  as a client does (`Troupe.Protocol.Daemon.ensure_running/1`, with this release's own
  wrapper where `RELEASE_ROOT` names one, so `open` starts the daemon it belongs to),
  waits for the WebSocket entry, and opens the default browser at
  `<web app>#daemon=<ws.port>:<ws.token>`. The web app is `--url`, or the one the plane
  the daemon is linked to serves at `/app/` (where the chart mounts it, Decision 670).
  Not linked and no `--url` is a message naming `--url`, and nothing is started. The
  plane is not asked where its app is: its discovery document does not say, and `open`
  works offline; a plane whose app is elsewhere (`plane.appUrl`) is `--url`'s. Nothing
  printed names the token: the address goes to the browser and nowhere else.
- **The origin, with no environment variable.** The loopback's default list is now this
  machine's origins (localhost on any port and the desktop shell's), the origin of the
  plane in `identity.json`, and the origins in `ws.origins` in `daemon.json`, the last
  two read at each upgrade (`Loopback.admitted/0`), since a link or an `open` comes after
  the daemon started. `open` adds the web app's origin to `ws.origins`
  (`Endpoint.admit_ws_origin/1`) before it opens the browser. Kept beside the token it
  goes with rather than in a file or a setting of its own: a daemon that starts again
  writes a fresh `ws` entry without it, so it lasts exactly as long as the token the page
  was handed, and whoever can write `daemon.json` can already read the token, so it
  admits nobody who could not already attach. `TROUPE_ALLOWED_ORIGINS` still replaces the
  whole list, read once as the daemon starts, as before. Not chosen: a protocol command
  to admit an origin, which widens the protocol for one command whose trust boundary is
  already this file; a `config.yaml` key, which outlives the token and is a setting a
  person did not write.
- **A refused upgrade is a warning in the daemon's log**, naming the origin and the fix
  (`open --url`, or the link; or, with `TROUPE_ALLOWED_ORIGINS` set, adding the origin to
  it), once a minute per origin, since a page left open dials again every few seconds. A
  browser shows the page no 403, only a socket that did not open, so the log is the one
  place the reason can be read. `Web` takes the list as a function and a callback for a
  refusal; a pod passes neither and is unchanged.
- **The token is on no command line where another user could read it.** On Linux every
  user can read every process's arguments (`/proc/<pid>/cmdline`), for as long as it
  runs, and a browser started with the address keeps it there; the token admits whoever
  holds it to everything the daemon does as this user. So outside Windows the browser is
  given `open.html` beside `daemon.json`, made `0600` before the address is written into
  it, which sends it on with a `meta` refresh (as Jupyter does for its token). Windows
  shows one user's command lines to no other user, and a `.html` file there may open in
  something that is not the browser, so there `start` is given the address.
  `BROWSER`, where set, is what opens it, as other tools read it: on Windows a program,
  elsewhere a command line the target is appended to.
- **The page.** `daemonHint()` reads `#daemon=`, takes it off the address bar with
  `history.replaceState` (keeping any other part of the fragment), and keeps the pair in
  `localStorage` under `troupe.daemon`; a later load reads it from there. A pair typed
  into *This computer* is kept the same way, and *Disconnect* forgets it.
  `VITE_TROUPE_DAEMON`, a developer's own file, still wins. A desktop shell keeps
  nothing: it reads `daemon.json` again.
- **The exception to "one persisted secret".** The GUI kept exactly one secret on disk,
  the identity provider's refresh token, and held the daemon's token in memory for the
  tab. The issue asked for `sessionStorage`; the maintainer chose `localStorage`, so a
  reload and a new tab reconnect, and this is that exception, said once here and in the
  code. Why it is acceptable: the token changes every time the daemon starts, so a kept
  one is good only until the next start, and a stale one fails and the page says to run
  `troupe-daemon open` again. What it costs: while the daemon runs, a script on the page's
  origin can read it, in any tab and on any page of that origin, not only in the app's tab
  while it is open. That is the plane's origin for the hosted app, and for a development
  server whatever is served at that `localhost` port later.
- **When the socket will not open**, the browser build says so in words: the daemon is
  not running, started again since the page was told, or does not admit pages from this
  page's origin, which it names, since a browser does not say which; then
  `troupe-daemon open`, and `--url` with this page's address. An answer from the daemon
  that is not `initialize`'s is shown as it was.
- **Left as it was.** A browser that never signed in at the plane's app opens on its
  sign-in screen, which now offers *Use this computer only* because the page knows the
  daemon; signing in there finds the pair still kept after the provider's redirect. A
  daemon `open` starts on Windows shares the terminal's console, as every client's spawn
  does (`detach_line/2`). The browser's own history may keep the address as it was first
  loaded; `replaceState` rewrites the page's entry.
- **Proof:** the gateway's `LoopbackTest`: an upgrade from the linked plane's origin is
  admitted while linked and not on another scheme or port or after unlinking, which was
  a 403 on the chunk's tip; an origin published beside the token is admitted and no
  other; `TROUPE_ALLOWED_ORIGINS` replaces all of it; a refusal is one warning naming the
  origin and `troupe-daemon open --url`. The daemon's `CLITest`: the grammar; no link and
  no `--url` starts and opens nothing; linked, it starts the daemon and opens
  `https://plane.example.test/app/#daemon=<port>:<token>` and prints neither token;
  `--url`'s origin admitted, and outside Windows a `0600` page with the address in it;
  how the browser is started, with and without `BROWSER`. The GUI's
  `daemon-open.test.tsx`: arriving at `#daemon=` shows the local sessions with the token
  gone from the address, and a load with nothing after the address connects again (both
  failing on the tip, which read the fragment and left it there); *Disconnect* forgets
  it; a socket that will not open names this page's origin and `troupe-daemon open`. And
  the installed daemon on Windows, with scratch homes, against the GUI's web build served
  on `127.0.0.1` and on `[::1]`, `BROWSER` recording what it was handed and a headless
  Chromium loading it: with no daemon running, `open --url` started one, printed no
  token, and the page showed the session on this computer with nothing after its
  address, and again after a reload; a page on `[::1]` was refused, said its origin,
  and the daemon logged one warning for it, until `open --url` for it admitted it;
  after the daemon was stopped, `open` again started a new one and the page connected at
  the new pair; linked to a plane at `[::1]`, `open` alone opened its `/app/`, with the
  daemon running and with none.
