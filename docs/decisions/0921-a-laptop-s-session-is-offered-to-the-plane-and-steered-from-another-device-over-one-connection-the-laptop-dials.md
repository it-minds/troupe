---
number: 921
title: "A person offers one of their laptop sessions to the plane, shared at offer time with the people they name; the laptop dials one connection the plane relays protocol messages over, both ends hold each message to one table and the laptop to its own record of the share, the plane keeps no copy, and a withdrawal or a drop ends every remote view at once"
date: 2026-10-18
status: accepted
issue: 58
paths:
  - apps/troupe_protocol/lib/troupe/protocol/relay.ex
  - apps/troupe_protocol/lib/troupe/protocol/endpoint.ex
  - apps/troupe_protocol/lib/troupe/protocol/event.ex
  - apps/troupe_protocol/lib/troupe/protocol/client.ex
  - apps/troupe_gateway/lib/troupe/gateway/remote.ex
  - apps/troupe_gateway/lib/troupe/gateway/remote/viewer.ex
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/plane.ex
  - apps/troupe_plane/lib/troupe/plane/remote.ex
  - apps/troupe_plane/lib/troupe/plane/remote/*.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/priv/repo/migrations/20261018000921_remote_sessions.exs
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/troupe/client/steering.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/gui/packages/client/src/remote.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/apps/desktop/src/views/Remote.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/console/src/views/Remote.tsx
  - PROTOCOL.md
symbols:
  - Troupe.Protocol.Relay
  - Troupe.Gateway.Remote
  - Troupe.Plane.Remote
gist: "Laptop dials /v1/relay, nothing listens; share made at offer time, laptop's record decides; one Relay table checked at both ends; no allow_session, fs, shell or tools remotely; plane keeps no copy"
---

#58, slice 1. The maintainer decided on 2026-10-18 that the first slice is full steering: a
laptop's daemon offers a session to the plane, and its owner and the people they share it
with can, from another device (the desktop app or the console), follow it, answer its
approvals and questions, send prompts, cancel a turn and switch its agent. This records how,
and what is left.

## One connection, dialled by the laptop

Nothing listens on the laptop. While at least one session is offered and a client has
handed the daemon a plane token (Decision 764), `Troupe.Gateway.Remote` keeps one WebSocket
open to the plane's `GET /v1/relay`, with that token in `Authorization`, renewed on the
open socket (`auth.refresh`) each time a client links again with a fresh one. A link naming
another person ends it; signing out or unlinking ends it and keeps the record. Over it the
daemon says what it offers (`relay.sync` as it connects, then `relay.offer` and
`relay.withdraw`), and the plane relays each remote person: `relay.open` names a viewer,
the person and the role the plane holds them to, `relay.frame` carries one protocol message
either way as a string, and `relay.close` ends one view. One connection per daemon rather
than per session, because the limit that matters is the plane's sockets, and a laptop
offering five sessions is one laptop.

The plane's half is `Troupe.Plane.Remote.Laptop` (the laptop's socket) and
`Troupe.Plane.Remote.Viewer` (`GET /v1/relay/session`, a person's). A laptop's connection
holds a `:global` name per session it offers, so a viewer on any replica finds it, and a
connection that dies takes its names with it: **online is a live connection**, not a column.
A page is not a laptop: `/v1/relay` refuses any request that names an `Origin`.

**Why not the control channel.** It is the pods' internal port, enrolled with a projected
ServiceAccount token, and its moduledoc and its tests promise it carries no session content.
A laptop is on the internet, authenticated as a person, and what it carries is content. A
second door on the public surface, with its own two sockets, keeps both promises.

**Why not a dedicated relay app.** The open question in #58. A relay inside the plane
reuses its token verification, its person rows and its clustering, and the seam the two
sockets give is narrow enough to move into its own app later without a client noticing:
clients only ever see `remote.open`'s endpoint.

## Each remote person is a connection like any other

The daemon makes each viewer the plane opens into a `Troupe.Gateway.Connection` on a new
`:relay` endpoint kind (`Troupe.Protocol.Endpoint.relay/2`), whose frames
`Troupe.Gateway.Remote.Viewer` owns, the same two-process shape as the loopback WebSocket.
So a remote prompt goes through the same dispatcher, the same session and the same rules as
one typed at the laptop: the enforced layer, the per-tool rules (Decision 907) and the
approvals apply inside the session whichever connection sent the input, and nothing about the
connection can widen them. Its principal is the person the plane named, with `via: "plane"`,
and `initialize` says `capabilities.relayed`.

## Who may steer, and checked at both ends

**A share made at offer time**, not the plane's existing sharing. `remote.offer` names
people by subject or email, each `observe` (follow) or `control` (steer); the plane resolves
them to people it knows and refuses one it does not by name, so a share never silently
reaches fewer people than were named. The owner, the person linked when it was offered, may
always steer it, from any of their devices. The plane's `session.grant` and share links are
for the plane's own rows, a pod session's ACL and a capability over it; folding a laptop's
offer into them would let a plane-side grant reach a laptop that never made it.

**One table, two checks.** `Troupe.Protocol.Relay` lists what a relayed connection may ask,
with the scope each needs, in the protocol app, because the plane may not call the daemon's
code and the daemon may not call the plane's. The plane checks each request from a viewer
against it, at the role the offer holds them to, before relaying it, and again asks the row
and the account before each steering command, so a share taken back or a deactivated person
stops at their next command. The daemon checks it again in the connection's guard, at the
narrower of the plane's role and **its own record** (`<state>/remote.json`): a person the
plane relays whom the laptop never named is closed before a word reaches the session, and a
plane that said `control` for somebody shared to `observe` gets them `observe`.

**What the table is.** The session's own reading (`subscribe` on its topics,
`session.get`, a listing narrowed to it, `blob.get`, `agents.list` of the session,
`commands.list`, `presence.set`, the goal and loop reads) and its steering (`input.send`,
`commands.run`, `turn.cancel`, `profile.switch`, `approval.respond`, `question.answer`,
`todo.edit`). A request naming another session, `fleet`, or a path's agents is refused.
**Nothing of the laptop**: no `fs.*` (editing files remotely is #61), no `shell.*` (a
person's own commands, Decision 813), no `tools.*` (the laptop's person's tools stay theirs,
and a remote person's machine offers none here), and no setting, server, workspace or
identity of the laptop.

**A remote person cannot loosen the laptop's rules.** An approval answered from another
device is `allow` or `deny`, for that one call; `allow_session`, which would stop the
session asking for that tool for the rest of it, is refused over the relay and is the
laptop person's to give at the laptop. Switching the agent is among the session's own
agents, the laptop's files, and the stricter rule still holds where they differ (Decision
907).

## Offline, withdrawn, and the record

**Withdrawn at once.** `remote.withdraw` closes every remote view of the session on the
daemon before the plane is told, so a plane that did not hear still relays nothing more;
the plane, told, ends its views with `relay.closed`. Erasing a session withdraws it.

**Offline honestly.** A dropped connection ends every view on both ends, the plane records
`offline_since` on the offer's row, `remote.list` says `offline` with it, and `remote.open`
is `unavailable` with `offline_since`. Nothing is queued: a viewer's message has nowhere to
go and is not kept. The daemon dials again, backing off from a second to a minute, and on
connecting sends `relay.sync` with exactly what its record still offers of the linked
person's; the plane keeps those and drops every other row of that person's from that device,
so a session withdrawn while the laptop was away is not offered again, and one still offered
is. The device is a random id the daemon keeps beside the record.

**The plane keeps no copy.** The row is who offered which session from which device, to
whom, and since when the laptop has been away, with the workspace's last name as a label;
nothing a session says. The plane relays each message and keeps none, no transcript copy:
a copy would be a second store of a laptop's content that the laptop's person cannot see,
erase or seal under their own key, and a private session exists precisely for the person who
wants their content off the laptop. A viewer replays from the laptop's log, which is the
session.

**A private session is never offered.** It is sealed under its person's key, its row is the
plane's on other terms (Decision 785), and steering it from another device is claiming it
there (`session.claim`). The daemon refuses the offer with that sentence.

**A token never reaches the laptop.** A viewer attaches with the token `remote.open` mints:
for one session, at one role, with the relay's own audience (`troupe-relay`), so it opens no
pod and no `/rpc`; at most fifteen minutes, renewed with `remote.open` again and `auth.refresh`
on the open socket, which the plane answers itself. The plane takes `auth` out of a viewer's
`initialize` before relaying it.

## The clients

- **The terminal**: `/remote` says whether the session is offered and who is steering;
  `/remote on [person[:observe] ...]` offers it, an email to steer and `:observe` to follow;
  `/remote off` withdraws it (`Troupe.Client.Steering`).
- **The desktop app**: a local session's head has *Steer from elsewhere*, then *Offered ·
  Online* with the people steering, *Share* and *Withdraw*. Its list has laptops' sessions
  as a `remote` kind, *Remote*, from the plane's `remote.list`, with *Offline since …* for an
  away laptop; this computer's own offered session stays its own row. Opening one attaches
  through `remote.open` exactly as a pod session attaches through `session.open`, and the
  head says *On Ada's laptop · Online*. Its approvals offer *Allow* and *Deny* and not the
  session-wide allow. A person's input sent from another device is drawn with *from another
  device*.
- **The console**: Sessions lists *Offered to you from laptops* apart from the
  administrative table, steered as the person and never as an administrator; opening one
  follows the transcript and answers its approvals (once) and questions, sends a prompt,
  stops a turn and switches its agent.
- **The laptop shows who is steering**: the session's listing carries `remote.steering`,
  the people attached through the plane now, and presence names them as anybody attached is.

## Limits, and later slices

- The daemon's plane token is a client's (Decision 764): with no client signed in on the
  laptop to renew it, the connection ends at the token's expiry and the session is offline
  until one links again. A daemon that renews its own sign-in is a later slice.
- The console is an administrator's app; a person with no administrative role steers from
  the desktop app. A person's console of their own is later.
- Admins forbidding remote steering per team (#58's open question) is not in this slice.
- No VS Code half: a TUI feature stays the TUI's.

## Proof

- `apps/troupe_protocol/test/troupe/protocol/relay_test.exs`: steering at `control`,
  reading at `observe`, the laptop's methods and another session refused, `allow_session`
  refused, the narrower role.
- `apps/troupe_gateway/test/troupe/gateway/remote_test.exs`, against `FakeRelay`: offered
  over one connection the daemon dials, the listing says so; a private session refused;
  nothing offered without a token; an unknown person refused and nothing recorded; the owner
  steering remotely, the transcript writing their input `via: "plane"`, a cancel; a shared
  person answering an approval once, `allow_session` refused; the daemon holding a person
  to its own record whatever the plane relays, and closing one it never shared with; only
  the session and nothing of the laptop; the listing naming who steers; a withdrawal ending
  every view at once; a drop ending the views, the daemon dialling again and offering only
  what it still does; a fresh token renewing the connection where it stands.
- `apps/troupe_plane/test/troupe/plane/remote_test.exs`, a laptop over a real socket: the
  owner and the shared find it, nobody else; an unknown person refused by name; another
  person's session refused; a page refused at `/v1/relay`; a shared person's messages
  relayed checked, a token never reaching the laptop, a renewal answered by the plane; an
  observer held to it on the plane; a plane token refused at the viewer's door; a withdrawal
  ending every view; an away laptop offline since then with nothing queued, and back again.
- `clients/tui/test/troupe/remote_command_test.exs`; `clients/gui/packages/client/test/remote.test.ts`;
  `clients/gui/apps/desktop/test/remote-sessions.test.tsx`; `clients/gui/apps/console/test/remote.test.tsx`.
