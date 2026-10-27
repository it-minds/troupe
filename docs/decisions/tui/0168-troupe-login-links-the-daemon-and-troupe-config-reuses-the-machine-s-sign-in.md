---
number: 168
title: "`troupe login` links the daemon on this machine with the plane token there and then, starting the installed troupe-daemon where none runs, and `troupe config` offers the plane the machine is signed in to instead of a second sign-in"
date: 2026-10-27
status: accepted
paths:
  - clients/tui/lib/troupe/cli/remote.ex
  - clients/tui/lib/troupe/cli/config_setup.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
  - clients/tui/test/troupe/private_link_test.exs
  - clients/tui/test/troupe/config_setup_test.exs
  - clients/tui/test/support/remote_helpers.ex
symbols:
  - Troupe.CLI.Remote.login/2
  - Troupe.Client.Daemon.Link.ours/3
  - Troupe.Client.Daemon.Link.link_params/3
gist: login links a running or freshly started daemon with the token, leaving somebody else's; config's plane choice defaults to the signed-in plane and skips the device flow
---

Root Decision 958. The installer's `troupe config` ran `troupe login`, which wrote
`credentials.json` and nothing more: the daemon was linked only when a `troupe` session
next attached (root 764), so a machine set up by the installer, with the daemon started at
login, had a daemon nobody had linked until somebody opened the terminal client.

- **Login links.** After the credentials are saved, `login/2` connects to the daemon
  (`Troupe.Protocol.Daemon.connect/1`, through the protocol door), asks `identity.get`,
  and where the daemon is unlinked or linked to this person at this plane sends
  `identity.link` with the plane token, as `Link` does on attach; the ownership test and
  the link's params are `Link.ours/3` and `Link.link_params/3`, public now, so the two
  cannot drift. It says who the daemon is linked to, or that it was somebody else's and
  left, or that it could not be reached. The `daemon:` option goes to the connect, and
  the tests pass `spawn: false` so no `troupe-daemon` on a developer's `PATH` is started.
- **Starting the daemon.** Where none is running, the installed `troupe-daemon` is
  started, as `troupe` would start one: the label persists in `identity.json`, and a
  daemon that restarts later is handed the token by the first client to connect. A
  machine with no `troupe-daemon` installed is told, and `troupe` links the daemon it
  embeds when it next opens. Not embedded here: a daemon embedded in `troupe login` dies
  with the command.
- **`troupe config` reuses the sign-in.** The plane choice's prompt defaults to the plane
  the machine is signed in to (`io.signed_in`, from `credentials.json`), and an answer
  that names it, or Enter, pulls its settings with the sign-in it has rather than running
  the device flow again. Another plane is signed in to as before.
- **Proof.** `private_link_test` (login links the daemon this VM embeds, with a token the
  fake plane honours, and says so; a daemon linked to somebody else is left with its own
  link and no token), `config_setup_test` (the prompt names the signed-in plane; Enter or
  the same plane pulls without a login; another plane logs in).
