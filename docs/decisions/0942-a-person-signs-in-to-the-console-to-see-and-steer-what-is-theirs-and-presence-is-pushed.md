---
number: 942
title: "Anybody the plane knows signs in to the console, a person who administers nothing as a member shown only Mine (their offered laptop sessions, steered as themselves, their sessions, their clients' versions and their memory to read) and an administrative role adds the four groups; and the laptop sessions offered to a person, and who is steering one, are pushed to the desktop app and the console, never polled: a person's watch at /v1/relay/watch sends remote.changed with the whole list when a change concerns them, and a session's presence topic names who arrives and leaves"
date: 2026-10-24
status: accepted
issue: 58
supersedes: [886]
paths:
  - apps/troupe_plane/lib/troupe/plane/remote.ex
  - apps/troupe_plane/lib/troupe/plane/remote/watch.ex
  - apps/troupe_plane/lib/troupe/plane/remote/laptop.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/clients_seen.ex
  - clients/gui/apps/console/src/App.tsx
  - clients/gui/apps/console/src/console.ts
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/apps/console/src/views/Shell.tsx
  - clients/gui/apps/console/src/views/Mine.tsx
  - clients/gui/apps/console/src/views/Remote.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/views/Remote.tsx
  - clients/gui/packages/client/src/remote.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/packages/client/src/session.ts
  - clients/gui/packages/client/src/transcript.ts
  - PROTOCOL.md
  - docs/admin/console.md
symbols:
  - Troupe.Plane.Remote.Watch
  - Troupe.Plane.Remote.changed/1
  - Troupe.Plane.ClientsSeen.of/1
gist: "Console signs in everybody, a member to Mine only, admins add the four groups; offers pushed over /v1/relay/watch (remote.changed), steering from presence:<id>; polls only as fallback"
---

#58's rest, pulled forward into chunk 42 by the maintainer on 2026-10-24. Two things were
left after slice 2 (Decision 928): a person who administers nothing could steer only from
the desktop app or the terminal, because the console signed in administrators and told
anybody else "Nothing to administer here"; and the desktop app learned of an offer, a
withdrawal or a laptop going away by asking `remote.list` again every four seconds, and
who was steering this computer's own session from the daemon's listing on the same poll.

## A person's own console

**Everybody the plane knows signs in.** The console's sign-in was already the plane's own
(the provider's code with PKCE, `/auth/exchange`, a plane token that says nothing of a
role), so nothing at the door changes. What changes is what the console makes of somebody
the plane answers no administrative role for: a **member** (`Role` in `nav.ts`), not a
refusal. `standing/2` still asks `me` and `admin.teams.list`; a `required_role` refusal now
means `member`.

**Mine, for every role.** A group of its own above the brief's four, holding one area: the
laptop sessions offered to the person, opened and steered from there; their own sessions on
the plane (`sessions.list`, theirs only); which version of each of their clients the plane
last saw against its policy (`me.clients`, new, `ClientsSeen.of/1`, the line
`admin.clients.get` already says of them to an administrator); and the memory their
machines read into every session (`me.memory`), to read and not to change. A member's map
is Mine alone and they start there; an administrator's is Mine and then the four groups,
and they still start at the Overview. Mine is not on the plane's map
(`Troupe.Plane.Admin.Console`), since no administrative method is placed there, so
`NAV` stays the plane's four groups and `MINE` is beside it.

**This takes back one line of Decision 886**, that the console "calls `admin.*` and `me`
and nothing else". Its administrative areas still do; Mine calls what any client of the
person's calls, and nothing that client could not.

**Nothing on Mine is an administrative call.** Each is what any client of the person's asks
the plane as that person, so the plane holds a member to what it holds the desktop app to:
`remote.list` and `remote.open` already answered per person (Decision 921), and a session
not offered to them is `not_found` at both and absent from their watch. The audit is what it
was: a steering command a member sends from the console is recorded on the laptop as theirs
with `via: "plane"`, as one sent from the desktop app is; nothing new is recorded.

**The laptop's sessions moved to Mine.** The administrators' Sessions page is metadata and
never what a session said; it no longer carries *Offered to you from laptops*, which is a
person's and on Mine. `#/sessions/remote/<id>` from before is sent to `#/mine/remote/<id>`.

**`/admin` is unchanged.** Its LiveView sign-in still refuses a person with no administered
team at `/admin/denied`; it is the break-glass page and not where a member goes.

## Presence is pushed

**A person's watch: `GET /v1/relay/watch`** (`Troupe.Plane.Remote.Watch`). The plane had no
socket a person's client held: `/rpc` is request and answer, and the relay's two doors are a
laptop's and one session's view. So there is a third, admitted from the pages a viewer's
door admits, taking the person's ordinary plane token at `initialize`. Its answer carries the
person's list as `remote.list` would (`sessions`), and from then on it sends `remote.changed
{sessions}`, the whole list, each time the list changes. The list is in the answer rather
than pushed behind it because a client reading a handshake can keep what arrived with the
answer in its buffer until its next read (the protocol's own Elixir client does).

**Told only what concerns them.** `Troupe.Plane.Remote.changed/1` broadcasts on the plane's
PubSub, on every replica, the subjects a change concerns: an offer's owner and the people it
is shared with, before and after (so one a share no longer names hears that it went). The
laptop's connection calls it once the change is in force: after `relay.sync`, `relay.offer`
and `relay.withdraw` with the names held or let go, and as it closes, having let go of its
names first, so a watch that reads again finds the laptop gone. Each watch reads its
person's list again only when named, and sends it only where it differs from the last one.
The whole list rather than a difference, so a missed message is mended by the next.

**Not chosen: a long poll on `/rpc`** (`remote.watch {since}` held open). One request per
person at a time, but each answer is a new request and a reconnect, a proxy's timeout is
the ceiling, and it is still a client asking. **Not chosen: riding the laptop's relay
connection** or the daemon's link: the person's other computer, or their browser, has
neither.

**Who is steering, from presence.** The daemon already publishes a session's presence on
`presence:<id>`, with `via: "plane"` for a person attached through the relay (Decision 928),
over the connection the desktop app holds to it. A view now follows that topic
(`SessionView.followPresence`, again on every new socket, never twice on one, and let go
with the view), and the desktop app's *Offered* line names who is steering from the
listing as it was and what presence said since: somebody arriving is added, somebody leaving
taken off. The client's fold took only a whole `members` list, which no server sends; it now
also takes one person's news, as the daemon and a pod send it, keeping one who left as
`left` so a list drawn from elsewhere can be told they went (`presentMembers`).

**What polls are left.** The fleet store's poll asks a watched source only while its watch
is down, and as a five-minute safety net (`fleetTiming.safetyNetMs`), so a plane from before
the watch is asked as it was; the console asks `remote.list` once at each failed dial. The
team half (`sessions.list`) and the daemon's own listing are still polled every four
seconds: they are not presence, and the daemon's `fleet` topic is a later change.

## Proof

- `apps/troupe_plane/test/troupe/plane/remote_test.exs`, a person's watch: an offer, a new
  share, the laptop going and a withdrawal reaching the people they concern within a second
  and nobody else; a member who administers nothing listing, watching and opening only what
  is offered to them, a relay token refused at the watch; a page from another origin refused.
- `apps/troupe_plane/test/troupe/plane/client_versions_test.exs`: `me.clients`, the person's
  own and nobody else's.
- `clients/gui/apps/console/test/remote.test.tsx`: offered sessions on Mine, steered;
  a member steering one, shown nothing not offered to them, refused one by its address; an
  offer, its laptop going and its withdrawal shown within a second with no `remote.list`
  asked again. `mine.test.tsx`, `signin.test.tsx` (a member lands on Mine with no
  administrative area), `shell.test.tsx`.
- `clients/gui/apps/desktop/test/remote-sessions.test.tsx`: an offer, its laptop going and its
  withdrawal shown within a second with no `remote.list` asked again; who is steering this
  computer's session named as they arrive and leave, from its presence.
