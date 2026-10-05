---
number: 764
title: A client signed in to a plane hands the daemon its plane token when it links it, when it reaches it, when the token is renewed and when the daemon restarted; a link that carries one is when the daemon carries on sealing what it could not; and both clients ask for a private session where the daemon reads it
date: 2026-10-04
status: accepted
issue: 365
paths:
  - ARCHITECTURE.md
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
  - apps/troupe_gateway/test/troupe/gateway/private_test.exs
  - clients/tui/lib/troupe/cli/remote.ex
gist: A client signed in to a plane hands the daemon its plane token when it links it, when it reaches it, when the token is renewed and when the daemon…
---

Issue #365, following 745 and
756. The daemon cannot obtain a plane token and holds the one it is handed in memory
only, and neither client handed it one: the desktop app's `linkIdentity` had no
`plane_token`, and the TUI never called `identity.link`. Nothing private was registered
or sealed from either. Four more things stood between either client and a sealed
private session, and are fixed here because the issue's done-when needs each.
- **The desktop app.** `linkIdentity` takes `plane_token`. `useDaemon` is given the
  sign-in and hands the token over where the daemon is linked to the person signed in,
  at this plane: when it reaches the daemon or the person signs in, for every token
  the `AuthSession` takes after that (`onCredential`, new: a renewal comes from the
  list's poll, two minutes before expiry), and when the socket opens again, which after
  a restart is a daemon holding none (745 follows it there). *Use my account* links
  with it. A daemon linked to nobody or to somebody else is not touched: linking stays
  the person's choice, on *This computer*.
- **The TUI.** Signed in (`troupe login`; the current plane in `credentials.json`),
  every new connection `Troupe.Client.Daemon.Link` makes hands the daemon the token,
  because a new connection may be to a daemon with none, one this VM just embedded or
  one that restarted; so does a timer a second after the store would renew the token,
  a minute before expiry (`Tokens.person/1`), and a minute after a hand-over the plane
  was not there for. The subject and name are the plane's, from `/auth/exchange`'s
  answer, now kept, or from `me` where it was asked. It links a daemon linked to nobody
  or to this person at this plane, and leaves one linked to somebody else. Unlike the
  desktop app it links an unlinked daemon: the TUI has no control to do it with, and
  signing in with `troupe login` is the person asking. Out of the link process, in a
  task, because a renewal is a round trip and the link is a call through it.
- **Asking for a private session.** The desktop app sent `private` inside `config`, a
  setting no client may choose, so *Keep it private* made a local session; it goes
  beside `config` now, where the daemon reads it and PROTOCOL.md now says so. The TUI
  had no way to ask: `troupe --private` and `troupe run --private`.
- **`private_sessions` on an installed daemon.** It asked for an object-store
  configuration, which a daemon never uses (it writes through the URLs its plane
  signs) and an installed one never has, so the desktop app offered no checkbox
  outside development. Somewhere to seal to is now the plane the link names. It is
  still computed at `initialize`, so a connection made before *Use my account* says
  false after it; the desktop app offers the checkbox where the daemon knows the
  capability and is linked now, rather than after the next launch.
- **Carrying on.** A sealer was started at `session.create` and nowhere else, so a
  private session made while nobody had linked was never sealed, and none was sealed
  again after a restart, though PROTOCOL.md promised a daemon with no token seals
  later. A link that carries a token now runs `Private.resume/1` after the erasures:
  for each private session the daemon has with no sealer (`kind` is in the index now,
  read from `session_created`), `session.get` decides. One the plane has never heard
  of is registered and sealed from its first event. One this device sealed last
  carries on from the row's `last_seq` with its `object_bytes`, registered with the
  row's epoch, so a claim another device made meanwhile refuses it. One another device
  sealed last is left to it: taking it back is a claim, which a person asks for. One
  being erased is the erasures'. Keyed on the row's `device`, the name a daemon
  registers under, so a machine whose name changed carries on nothing until it claims.
- **The sealer starts partway.** It takes what the log holds after its starting point
  (`:backfill`), asked after it subscribes, and drops an event it already holds. So a
  session that starts sealing as it is created now also seals the events its start
  wrote before the sealer subscribed, `session_created` among them, which no sealed
  private session had until now. A pod passes no backfill and seals as before.
- **Unchanged:** the token is in no file and no answer; `identity.json` holds the
  label. A link without one is the label alone. The daemon's `session.list` still does
  not say a session is private, so the desktop app lists one as local.
- **Proof:** the client's `stage2` (a link carries the token and no answer does; its
  type refused it on the tip) and the desktop app's `private-link` test against the
  fake deployment with plane tokens of 125 seconds (handed over on reaching the
  daemon and again renewed, both honoured by the plane; handed to a restarted daemon;
  none to a daemon linked to somebody else; *Use my account* with it, the checkbox on
  a connection that said no private sessions, and `private` beside `config`), three
  of four failing on the tip. The TUI's `private_link_test`
  against `FakeRemote` on the POST transport, whose `/rpc` honours only the tokens it
  minted (linked with the token on attach and a private session registered with it;
  a renewed token handed over; a restarted daemon linked again; one linked to
  somebody else left), three failing on the tip, and `cli_test` for `--private`. The
  gateway's `private_test` against MinIO (a session sealed before a restart carried on
  once linked, from `last_seq` at its epoch, its later events in a second segment; one
  another device took left to it; one made while unlinked registered and sealed from
  its first event, an event delivered twice sealed once; a renewed token sealing what
  waited for it; through the daemon, a link registering a session made while unlinked,
  the token in no file) and `daemon_test` (`private_sessions` with no object store),
  all failing on the tip but the renewal, which the daemon already took and is kept
  as a pin. And the installed daemon and `troupe`, with scratch homes, against a plane
  stand-in that signs real assertions through the development OpenBao and presigns
  real MinIO URLs: the desktop app's client library linked the daemon with its token
  and a private session was registered and sealed; `troupe login` and `troupe run
  --headless --private` likewise; after the daemon was killed and started again, the
  TUI's next attach handed it a token, and the daemon registered the two sessions from
  before the restart again at epoch 1 and sealed the one the run had just made, while
  it had no token, from its first event; and a turn added to the first session then
  was sealed from the next sequence number on.
