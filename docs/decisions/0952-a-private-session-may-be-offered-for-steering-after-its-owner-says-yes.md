---
number: 952
title: "The owner may offer a private session for steering after saying yes to its passing through the plane unsealed while it is offered; the clients ask in one sentence first, the plane relays it to the people invited with control and keeps none of it, a control invitee steers it only while it is offered and their invitation stands, and withdrawing returns it to sealed-only"
date: 2026-10-25
status: accepted
issue: 765
supersedes: [921, 949]
paths:
  - apps/troupe_protocol/lib/troupe/protocol/relay.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_gateway/lib/troupe/gateway/remote.ex
  - apps/troupe_gateway/lib/troupe/gateway/invites.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/remote_test.exs
  - apps/troupe_gateway/test/troupe/gateway/invites_test.exs
  - apps/troupe_plane/lib/troupe/plane/remote.ex
  - apps/troupe_plane/lib/troupe/plane/remote/*.ex
  - apps/troupe_plane/lib/troupe/plane/invites.ex
  - apps/troupe_plane/priv/repo/migrations/20261025000952_remote_sessions_private.exs
  - apps/troupe_plane/test/troupe/plane/remote_test.exs
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/troupe/client/steering.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/steer_command_test.exs
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/packages/client/src/invites.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/apps/desktop/src/views/Remote.tsx
  - clients/gui/apps/console/src/views/Invited.tsx
  - clients/gui/apps/console/src/views/Remote.tsx
  - docs/user/README.md
  - docs/user/sessions-shared.md
  - docs/admin/security.md
  - PROTOCOL.md
symbols:
  - Troupe.Protocol.Relay.private_consent/0
  - Troupe.Gateway.Remote.reshare/1
  - Troupe.Gateway.Invites.invited/2
  - Troupe.Plane.Remote.role/2
gist: "A private session is offered only with consent: private, the clients asking Relay.private_consent first; shared with its control invitees; the plane keeps none of it; withdraw seals it only"
---

#765. The maintainer decided on 2026-10-25, from what chunk 44 found (posted on #765): *a
private session may be offered for steering, with consent.* Decision 921 is lifted that far:
the owner may offer a private session to the plane; while it is offered the relay carries
its content through the plane in the clear, and both clients say so before the offer is
made. A `control` invitee can then steer it; withdrawing the offer returns the session to
sealed-only, and an invitee without the offer reads the sealed log through their own daemon,
as Decision 949 has it.

## What this lifts

From Decision 921, *Offline, withdrawn, and the record*, the paragraph that reads:

> **A private session is never offered.** It is sealed under its person's key, its row is
> the plane's on other terms (Decision 785), and steering it from another device is claiming
> it there (`session.claim`). The daemon refuses the offer with that sentence.

From Decision 949, *A private session*, the paragraph *Followed, not steered*, which refused
`control` on a private session's invitation because of that sentence and left lifting it to
the maintainer. Everything else in both stands: the relay's one table, the laptop's record
deciding, the plane keeping no copy, the key following the invitation, revoking re-keying
forward.

## The consent gate

**Asked first, in one sentence.** `Troupe.Protocol.Relay.private_consent/0`:

> This session is private: while it is offered, what it says and does passes through the
> plane unsealed, and the plane relays it to whoever you invited with control. The plane
> keeps none of it. Offer it?

`remote.offer` on a private session without `consent: "private"` is `forbidden` with
`data.consent: "private"` and that sentence as `data.reason`, so a client that never heard
of this still shows the person why. The terminal's `/steer on` shows it on the status line in
the colour that means a person is needed (TUI Decision 126's pink) and says `/steer on yes
offers it`; the desktop app's *Steer from elsewhere* opens it with *Offer it* and *Keep it
sealed*, pink-edged, and nothing is offered until *Offer it*. The sentence lives in the
protocol app because the daemon and the plane both say it; the terminal, which reaches the
harness only through the daemon, keeps a copy its suite holds equal to it
(`Troupe.Client.Steering.private_consent/0`), and the desktop app has the same words as
`PRIVATE_OFFER_SENTENCE`.

**Asked at each offer, not remembered.** A yes is for the offer it is given to. Withdrawing
and offering again asks again. Kept as a setting, it would be a choice the person made once
and forgot; asked, it is said at the moment it matters.

## Whom it is shared with

**Its `control` invitees, and nobody named besides.** The sentence says "whoever you invited
with control", so the offer is shared with exactly that: the people the session's own log
says are invited with `control` (`Troupe.Gateway.Invites.invited/2`, the same log Decision
949 decides keys from). Naming people in `share` is `invalid_params`: the invitation, with
its key in their slot and its audit row, is how somebody is let into a private session, and a
share made at offer time would be a second door with neither. An `observe` invitee reads the
sealed copy as before, offered or not.

**Shared anew as invitations change.** An invitation made or taken back on the owner's
machine calls `Remote.reshare/1`: the record's share is recomputed from the log, a viewer it
no longer names is closed at once with *Your invitation into this private session was taken
back: you no longer steer it.*, and `relay.offer` tells the plane.

**The plane holds them to the invitation too.** `Troupe.Plane.Remote.role/2` on a private
offer is the narrower of the share's role and the person's invitation's; no invitation, no
role. So an invitation taken back at the plane, or anywhere the laptop has not heard of yet,
ends their steering there: `Invites.uninvite/3` sends the laptop's connection
`{:offer_changed, id}`, which rechecks every view it carries and closes the one whose person
no longer holds a role, and every steering command already asks the row again (Decision 921).
A private offer is so where the laptop says `private` or where the plane's own row of the
session is `private`, whatever the laptop said.

## The plane keeps none of it

The relay was already a pass-through: `Troupe.Plane.Remote.Laptop` and `Viewer` hold frames
only in flight, and the row (`remote_sessions`) is who offered what to whom. It gains
`private`. What is written per offer is the audit row `remote.offer` with the device,
`private` and how many it is shared with. The plane suite proves the rest by looking: after a
prompt and an event carrying a marker are relayed both ways, no row of any table on the plane
holds it.

## What the clients say

- **The listing.** The daemon's `remote` carries `private: true`, so does the plane's
  `remote.list` row, so the people steering see what they are steering: the desktop app's pill
  reads *Offered · Private · Online*, its head on another device *On Ada's laptop · Online ·
  private, passing through the plane unsealed while it is offered*, the console's offered list
  *private, unsealed while offered*, and `/steer` *Offered to the plane, private, …: what it
  says passes through the plane unsealed while it is offered*.
- **The invitee's view.** A private session's invitation carries `offered` (its offer row is
  there and its laptop online), pushed over the watch as it changes, since the watch now
  re-tells both lists on either change. A `control` invitation reads *offered · you can steer*
  or *not offered · read-only* (`steerWords`), in the desktop app's list and head and the
  console's *Invited to you*, which links to steering it while it is offered.
- **Withdrawing.** Every view closes with *The owner withdrew the offer: this private session
  is sealed-only again, and what it says no longer passes through the plane.*, the listing
  drops `private`, and the invitee's own daemon goes on reading the sealed copy.

## Sealing is unchanged

The offer is in addition to the sealed copy, never instead: `Troupe.Gateway.Private`'s sealer
runs as before, under the same key, and nothing in the relay path reads or changes it.

## Not in this

- Pod sessions: their invitation is their grant, steered through the pod as before.
- The terminal reading a shared private session (D137).
- An `observe` invitee following through the relay while it is offered: they read the sealed
  copy, which is what their invitation promised.

## Proof

- `apps/troupe_gateway/test/troupe/gateway/remote_test.exs`: a private session's offer without
  the yes refused with `consent` and the sentence and nothing relayed, naming somebody refused,
  with it offered `private` to its control invitee alone; a control invitee steering through
  the relay, written as theirs `via: "plane"`, closed at once with the sentence when the log
  takes the invitation back and the offer is shared anew, and again with the withdrawal's
  sentence. Both failed on the chunk's tip.
- `apps/troupe_gateway/test/troupe/gateway/invites_test.exs`: an invitation to steer made as one
  to follow is, every key in the invitee's slot, the offer shared anew at the invitation and its
  removal (real MinIO and OpenBao); it failed on the tip.
- `apps/troupe_plane/test/troupe/plane/remote_test.exs`: listed `private` to the control invitee
  and to nobody the invitation does not name, `offered` on the invitation, audited as
  `remote.offer` with `private: true`, a relayed prompt and event leaving nothing on any table,
  revoking closing the view with the sentence and refusing `remote.open`; the plane's own row
  making an offer private, withdrawing closing it with the sentence and `offered: false`. Both
  failed on the tip; `invites_test.exs` now invites to steer a private session.
- `clients/tui/test/troupe/steer_command_test.exs`: `/steer on` on a private session asks in the
  sentence, drawn in the reserved colour, and `/steer on yes` goes to the daemon.
- `clients/gui`: the desktop app's `remote-sessions.test.tsx` (the question, *Keep it sealed*
  offering nothing, *Offer it* with `consent`, shared with the control invitee, *Private* in the
  pill) and `invites.test.tsx` (*not offered · read-only*, then *offered · you can steer*); the
  console's `invited.test.tsx` (the words pushed both ways and the link to steer it).
